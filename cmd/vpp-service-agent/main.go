package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/kube"
	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/service"
	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/vppcnat"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	kubeconfig := flag.String("kubeconfig", os.Getenv("KUBECONFIG"), "kubeconfig 文件；为空时使用 in-cluster config")
	apiSocket := flag.String("api-socket", "/run/vpp-goal001/api.sock", "VPP Binary API socket")
	retry := flag.Duration("retry", 5*time.Second, "reconcile 重试与全量核对间隔")
	metricsListen := flag.String("metrics-listen", "", "可选的 loopback HTTP /metrics 与 /status 监听地址")
	flag.Parse()

	var config *rest.Config
	var err error
	if *kubeconfig != "" {
		config, err = clientcmd.BuildConfigFromFlags("", *kubeconfig)
	} else {
		config, err = rest.InClusterConfig()
	}
	if err != nil {
		log.Fatal(fmt.Errorf("读取 Kubernetes 配置: %w", err))
	}
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatal(fmt.Errorf("创建 Kubernetes client: %w", err))
	}
	controller := &kube.Controller{
		Kubernetes: client,
		OpenVPP: func() (kube.DataplaneConnection, error) {
			return vppcnat.Connect(*apiSocket)
		},
		Store:      &service.Store{},
		Logger:     log.Default(),
		RetryEvery: *retry,
	}
	if *metricsListen != "" {
		host, _, err := net.SplitHostPort(*metricsListen)
		if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
			log.Fatalf("metrics-listen 必须是明确的 loopback IP:port: %q", *metricsListen)
		}
		listener, err := net.Listen("tcp", *metricsListen)
		if err != nil {
			log.Fatal(fmt.Errorf("监听 metrics: %w", err))
		}
		server := &http.Server{Handler: kube.MetricsHandler(controller), ReadHeaderTimeout: 3 * time.Second}
		defer func() {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if err := server.Shutdown(ctx); err != nil {
				log.Printf("关闭 metrics HTTP: %v", err)
			}
		}()
		go func() {
			if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
				log.Printf("metrics HTTP 退出: %v", err)
			}
		}()
		log.Printf("metrics listening on %s", listener.Addr())
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := controller.Run(ctx); err != nil {
		log.Fatal(err)
	}
	log.Printf("controller stopped: %+v", controller.Counters())
}
