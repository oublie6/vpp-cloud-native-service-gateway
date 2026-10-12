package main

import (
	"context"
	"flag"
	"fmt"
	"log"
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
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := controller.Run(ctx); err != nil {
		log.Fatal(err)
	}
	log.Printf("controller stopped: %+v", controller.Counters())
}
