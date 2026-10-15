package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	"go.fd.io/govpp"
	"go.fd.io/govpp/binapi/feature"
	interfaces "go.fd.io/govpp/binapi/interface"
)

const apiSocket = "/run/vpp-goal001/api.sock"

// 仅给 Goal001 拥有的 tap102 启用隔离 CNAT 候选插件的 input feature。
func main() {
	if len(os.Args) != 2 || (os.Args[1] != "enable" && os.Args[1] != "disable") {
		fmt.Fprintln(os.Stderr, "用法: goal006-feature enable|disable")
		os.Exit(2)
	}
	if err := run(os.Args[1] == "enable"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(enable bool) error {
	if _, err := os.Stat("/run/vpp-goal001/topology-owned"); err != nil {
		return fmt.Errorf("Goal001 ownership marker 不存在: %w", err)
	}
	conn, err := govpp.Connect(apiSocket)
	if err != nil {
		return fmt.Errorf("连接 VPP Binary API: %w", err)
	}
	defer conn.Disconnect()
	ch, err := conn.NewAPIChannel()
	if err != nil {
		return fmt.Errorf("创建 API channel: %w", err)
	}
	err = ch.CheckCompatiblity(&feature.FeatureEnableDisable{}, &feature.FeatureEnableDisableReply{}, &interfaces.SwInterfaceDump{}, &interfaces.SwInterfaceDetails{})
	ch.Close()
	if err != nil {
		return fmt.Errorf("VPP 24.10 feature/interface API 不兼容: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	stream, err := interfaces.NewServiceClient(conn).SwInterfaceDump(ctx, &interfaces.SwInterfaceDump{})
	if err != nil {
		return fmt.Errorf("查询 VPP interface: %w", err)
	}
	defer stream.Close()
	for {
		detail, err := stream.Recv()
		if err == io.EOF {
			return fmt.Errorf("找不到 Goal001 interface tap102")
		}
		if err != nil {
			return fmt.Errorf("读取 VPP interface dump: %w", err)
		}
		if detail.InterfaceName != "tap102" {
			continue
		}
		reply, err := feature.NewServiceClient(conn).FeatureEnableDisable(ctx, &feature.FeatureEnableDisable{
			SwIfIndex:   detail.SwIfIndex,
			Enable:      enable,
			ArcName:     "ip4-unicast",
			FeatureName: "cnat-input-ip4",
		})
		if err != nil {
			return fmt.Errorf("修改 tap102 CNAT input feature: %w", err)
		}
		if reply.Retval != 0 {
			return fmt.Errorf("修改 tap102 CNAT input feature retval=%d", reply.Retval)
		}
		fmt.Printf("tap102 cnat-input-ip4 enabled=%t sw_if_index=%d retval=%d\n", enable, detail.SwIfIndex, reply.Retval)
		return nil
	}
}
