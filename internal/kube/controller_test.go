package kube

import (
	"context"
	"io"
	"log"
	"net/netip"
	"sync"
	"testing"
	"time"

	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/service"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

type observedDataplane struct {
	mu     sync.Mutex
	state  map[service.TranslationKey]service.Translation
	writes int
}

func (d *observedDataplane) List(context.Context) ([]service.Translation, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	var result []service.Translation
	for _, item := range d.state {
		result = append(result, item)
	}
	return result, nil
}

func (d *observedDataplane) Upsert(_ context.Context, item service.Translation) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.state[item.Key] = item
	d.writes++
	return nil
}

func (d *observedDataplane) Delete(_ context.Context, key service.TranslationKey) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.state, key)
	d.writes++
	return nil
}

func (d *observedDataplane) Close() {}

func (d *observedDataplane) snapshot() (int, int, int) {
	d.mu.Lock()
	defer d.mu.Unlock()
	backendCount := 0
	for _, item := range d.state {
		backendCount += len(item.Backends)
	}
	return len(d.state), backendCount, d.writes
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for controller state")
}

func TestControllerWatchesAndReconcilesFakeAPI(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := fake.NewClientset()
	dp := &observedDataplane{state: make(map[service.TranslationKey]service.Translation)}
	controller := &Controller{
		Kubernetes: client,
		OpenVPP:    func() (DataplaneConnection, error) { return dp, nil },
		Store:      &service.Store{},
		Logger:     log.New(io.Discard, "", 0),
		RetryEvery: 50 * time.Millisecond,
	}
	done := make(chan error, 1)
	go func() { done <- controller.Run(ctx) }()
	waitFor(t, func() bool { return controller.Counters().Attempts > 0 })

	svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Namespace: "test", Name: "echo", Annotations: map[string]string{VIPAnnotation: "198.19.0.20"}}, Spec: corev1.ServiceSpec{ClusterIP: "10.96.0.20", Ports: []corev1.ServicePort{{Name: "udp", Protocol: corev1.ProtocolUDP, Port: 18080}}}}
	if _, err := client.CoreV1().Services("test").Create(ctx, svc, metav1.CreateOptions{}); err != nil {
		t.Fatal(err)
	}
	slice := &discoveryv1.EndpointSlice{ObjectMeta: metav1.ObjectMeta{Namespace: "test", Name: "echo-a", Labels: map[string]string{discoveryv1.LabelServiceName: "echo"}}, AddressType: discoveryv1.AddressTypeIPv4, Ports: []discoveryv1.EndpointPort{{Name: stringPtr("udp"), Protocol: ptrProtocol(corev1.ProtocolUDP), Port: int32Ptr(18080)}}, Endpoints: []discoveryv1.Endpoint{{Addresses: []string{"10.10.2.2"}}}}
	if _, err := client.DiscoveryV1().EndpointSlices("test").Create(ctx, slice, metav1.CreateOptions{}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { count, backends, _ := dp.snapshot(); return count == 1 && backends == 1 })
	_, _, writes := dp.snapshot()
	if _, err := client.DiscoveryV1().EndpointSlices("test").Update(ctx, slice, metav1.UpdateOptions{}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(120 * time.Millisecond)
	if _, _, after := dp.snapshot(); after != writes {
		t.Fatalf("duplicate event wrote VPP again: before=%d after=%d", writes, after)
	}
	slice.Endpoints = append(slice.Endpoints, discoveryv1.Endpoint{Addresses: []string{"10.10.2.3"}})
	if _, err := client.DiscoveryV1().EndpointSlices("test").Update(ctx, slice, metav1.UpdateOptions{}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { _, backends, _ := dp.snapshot(); return backends == 2 })
	if err := client.CoreV1().Services("test").Delete(ctx, svc.Name, metav1.DeleteOptions{}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { count, _, _ := dp.snapshot(); return count == 0 })
	if controller.Counters().Changes < 3 {
		t.Fatalf("expected add/update/delete: %+v", controller.Counters())
	}
	_, snapshot := controller.Store.Snapshot()
	if len(snapshot) != 0 {
		t.Fatalf("desired state should be empty after Service deletion: %+v", snapshot)
	}
	if service.IsManagedVIP(netip.MustParseAddr("198.18.0.10")) {
		t.Fatal("Goal 002 VIP must remain outside Goal 003 ownership")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
