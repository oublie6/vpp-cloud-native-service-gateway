package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/service"
	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/vppcnat"
)

func main() {
	apiSocket := flag.String("api-socket", "/run/vpp-goal001/api.sock", "VPP Binary API socket")
	desiredPath := flag.String("desired", "", "JSON desired Service 快照文件")
	flag.Parse()
	if *desiredPath == "" {
		fmt.Fprintln(os.Stderr, "必须指定 -desired JSON 文件")
		os.Exit(2)
	}
	if err := run(*apiSocket, *desiredPath); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(socket, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("读取 desired snapshot %s: %w", path, err)
	}
	var desired []service.Service
	if err := json.Unmarshal(data, &desired); err != nil {
		return fmt.Errorf("解析 desired snapshot %s: %w", path, err)
	}
	client, err := vppcnat.Connect(socket)
	if err != nil {
		return err
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	changed, err := (service.Reconciler{Dataplane: client}).Reconcile(ctx, desired)
	if err != nil {
		return err
	}
	fmt.Printf("reconciled services=%d changed=%d verified=true\n", len(desired), changed)
	return nil
}
