package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"runtime/debug"
	"time"

	"go.fd.io/govpp"
	"go.fd.io/govpp/binapi/vpe"
)

func main() {
	path := os.Getenv("VPP_API_SOCKET")
	if path == "" {
		path = "/run/vpp-goal001/api.sock"
	}
	apiSocket := flag.String("api-socket", path, "VPP Binary API socket path")
	flag.Parse()
	if err := probe(*apiSocket); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func probe(path string) error {
	fmt.Printf("API socket: %s\n", path)
	conn, err := govpp.Connect(path)
	if err != nil {
		return fmt.Errorf("连接 VPP Binary API socket %q: %w", path, err)
	}
	defer conn.Disconnect()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	reply, err := vpe.NewServiceClient(conn).ShowVersion(ctx, &vpe.ShowVersion{})
	if err != nil {
		return fmt.Errorf("ShowVersion Binary API 请求失败: %w", err)
	}
	fmt.Printf("VPP program: %s\nVPP version: %s\n", reply.Program, reply.Version)
	fmt.Printf("Build date: %s\nBuild directory: %s\n", reply.BuildDate, reply.BuildDirectory)
	fmt.Printf("GoVPP version: %s\n", govppVersion())
	return nil
}

func govppVersion() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			if dep.Path == "go.fd.io/govpp" {
				return dep.Version
			}
		}
	}
	return "unknown"
}
