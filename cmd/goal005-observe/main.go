package main

import (
	"context"
	"fmt"
	"os"
	"time"

	goaltypes "github.com/oublie6/vpp-cloud-native-service-gateway/internal/goal005binapi/interface_types"
	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/goal005binapi/observe"
	"go.fd.io/govpp"
	interfaces "go.fd.io/govpp/binapi/interface"
)

const apiSocket = "/run/vpp-goal001/api.sock"

func main() {
	if len(os.Args) != 3 || (os.Args[1] != "enable" && os.Args[1] != "disable") {
		fmt.Fprintln(os.Stderr, "用法: goal005-observe enable|disable <VPP-interface>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(action, name string) error {
	conn, err := govpp.Connect(apiSocket)
	if err != nil {
		return fmt.Errorf("连接 VPP Binary API: %w", err)
	}
	defer conn.Disconnect()
	ch, err := conn.NewAPIChannel()
	if err != nil {
		return fmt.Errorf("创建 API channel: %w", err)
	}
	err = ch.CheckCompatiblity(&observe.Goal005ObserveEnableDisable{}, &observe.Goal005ObserveEnableDisableReply{}, &interfaces.SwInterfaceDump{}, &interfaces.SwInterfaceDetails{})
	ch.Close()
	if err != nil {
		return fmt.Errorf("Goal 005 Binary API schema 不兼容: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	stream, err := interfaces.NewServiceClient(conn).SwInterfaceDump(ctx, &interfaces.SwInterfaceDump{})
	if err != nil {
		return fmt.Errorf("查询 VPP interface: %w", err)
	}
	for {
		detail, err := stream.Recv()
		if err != nil {
			return fmt.Errorf("未找到 VPP interface %q: %w", name, err)
		}
		if detail.InterfaceName != name {
			continue
		}
		reply, err := observe.NewServiceClient(conn).Goal005ObserveEnableDisable(ctx, &observe.Goal005ObserveEnableDisable{
			EnableDisable: action == "enable",
			SwIfIndex:     goaltypes.InterfaceIndex(detail.SwIfIndex),
		})
		if err != nil {
			return fmt.Errorf("%s %s: %w", action, name, err)
		}
		fmt.Printf("%s %s sw_if_index=%d retval=%d\n", action, name, detail.SwIfIndex, reply.Retval)
		return nil
	}
}
