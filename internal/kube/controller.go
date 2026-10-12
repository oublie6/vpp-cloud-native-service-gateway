package kube

import (
	"context"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/service"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	corelisters "k8s.io/client-go/listers/core/v1"
	discoverylisters "k8s.io/client-go/listers/discovery/v1"
	"k8s.io/client-go/tools/cache"
)

type DataplaneConnection interface {
	service.Dataplane
	Close()
}

type Controller struct {
	Kubernetes kubernetes.Interface
	OpenVPP    func() (DataplaneConnection, error)
	Store      *service.Store
	Logger     *log.Logger
	RetryEvery time.Duration

	attempts    atomic.Uint64
	failures    atomic.Uint64
	changes     atomic.Uint64
	statusMu    sync.RWMutex
	lastSuccess time.Time
	lastFailure time.Time
	lastError   string
}

type Counters struct {
	Attempts uint64
	Failures uint64
	Changes  uint64
}

func (c *Controller) Counters() Counters {
	return Counters{Attempts: c.attempts.Load(), Failures: c.failures.Load(), Changes: c.changes.Load()}
}

type Status struct {
	Counters    Counters  `json:"counters"`
	LastSuccess time.Time `json:"lastSuccess,omitempty"`
	LastFailure time.Time `json:"lastFailure,omitempty"`
	LastError   string    `json:"lastError,omitempty"`
}

func (c *Controller) Status() Status {
	c.statusMu.RLock()
	defer c.statusMu.RUnlock()
	return Status{Counters: c.Counters(), LastSuccess: c.lastSuccess,
		LastFailure: c.lastFailure, LastError: c.lastError}
}

func (c *Controller) recordResult(err error) {
	c.statusMu.Lock()
	defer c.statusMu.Unlock()
	if err != nil {
		c.lastFailure = time.Now().UTC()
		c.lastError = err.Error()
	} else {
		c.lastSuccess = time.Now().UTC()
		c.lastError = ""
	}
}

func (c *Controller) Run(ctx context.Context) error {
	if c.Kubernetes == nil || c.OpenVPP == nil {
		return fmt.Errorf("Kubernetes client 与 OpenVPP 必须配置")
	}
	if c.Store == nil {
		c.Store = &service.Store{}
	}
	if c.Logger == nil {
		c.Logger = log.Default()
	}
	interval := c.RetryEvery
	if interval <= 0 {
		interval = 5 * time.Second
	}

	factory := informers.NewSharedInformerFactory(c.Kubernetes, 0)
	serviceInformer := factory.Core().V1().Services()
	sliceInformer := factory.Discovery().V1().EndpointSlices()
	signals := make(chan struct{}, 1)
	signal := func() {
		select {
		case signals <- struct{}{}:
		default:
		}
	}
	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { signal() },
		UpdateFunc: func(any, any) { signal() },
		DeleteFunc: func(any) { signal() },
	}
	if _, err := serviceInformer.Informer().AddEventHandler(handler); err != nil {
		return fmt.Errorf("注册 Service informer: %w", err)
	}
	if _, err := sliceInformer.Informer().AddEventHandler(handler); err != nil {
		return fmt.Errorf("注册 EndpointSlice informer: %w", err)
	}
	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), serviceInformer.Informer().HasSynced, sliceInformer.Informer().HasSynced) {
		return fmt.Errorf("Service/EndpointSlice informer 初始缓存未同步")
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	signal()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-signals:
		case <-ticker.C:
		}
		c.attempts.Add(1)
		if err := c.reconcileCache(ctx, serviceInformer.Lister(), sliceInformer.Lister()); err != nil {
			c.failures.Add(1)
			c.recordResult(err)
			c.Logger.Printf("reconcile failed: %v", err)
		} else {
			c.recordResult(nil)
		}
	}
}

func (c *Controller) reconcileCache(ctx context.Context, services corelisters.ServiceLister, slices discoverylisters.EndpointSliceLister) error {
	serviceObjects, err := services.List(labels.Everything())
	if err != nil {
		return fmt.Errorf("列出 Service 缓存: %w", err)
	}
	sliceObjects, err := slices.List(labels.Everything())
	if err != nil {
		return fmt.Errorf("列出 EndpointSlice 缓存: %w", err)
	}
	desired, err := BuildDesired(serviceObjects, sliceObjects)
	if err != nil {
		return fmt.Errorf("归一化 Kubernetes desired state: %w", err)
	}
	generation, err := c.Store.Replace(desired)
	if err != nil {
		return fmt.Errorf("更新 desired-state store: %w", err)
	}
	connection, err := c.OpenVPP()
	if err != nil {
		return fmt.Errorf("连接 VPP: %w", err)
	}
	defer connection.Close()
	_, snapshot := c.Store.Snapshot()
	changed, err := (service.Reconciler{Dataplane: connection}).Reconcile(ctx, snapshot)
	if err != nil {
		return fmt.Errorf("generation=%d: %w", generation, err)
	}
	c.changes.Add(uint64(changed))
	c.Logger.Printf("reconciled generation=%d services=%d changed=%d", generation, len(snapshot), changed)
	return nil
}
