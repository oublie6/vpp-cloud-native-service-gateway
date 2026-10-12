package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"go.fd.io/govpp"
	"go.fd.io/govpp/binapi/fib_types"
	interfaces "go.fd.io/govpp/binapi/interface"
	"go.fd.io/govpp/binapi/interface_types"
	"go.fd.io/govpp/binapi/ip"
	"go.fd.io/govpp/binapi/ip_types"
)

const (
	clientInterface = "tap101"
	serverInterface = "tap102"
	clientGateway   = "10.10.1.1/24"
	serverGateway   = "10.10.2.1/24"
	testRoute       = "198.18.0.3/32"
	testNextHop     = "10.10.2.2"
)

func main() {
	apiSocket := flag.String("api-socket", "/run/vpp-goal001/api.sock", "VPP Binary API socket")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "用法: goal002-fib [-api-socket PATH] setup|cleanup|route-add|route-del")
		os.Exit(2)
	}
	if err := run(*apiSocket, flag.Arg(0)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(socket, action string) error {
	if action != "setup" && action != "cleanup" && action != "route-add" && action != "route-del" {
		return fmt.Errorf("未知操作 %q", action)
	}
	conn, err := govpp.Connect(socket)
	if err != nil {
		return fmt.Errorf("连接 VPP Binary API %s: %w", socket, err)
	}
	defer conn.Disconnect()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	ifClient := interfaces.NewServiceClient(conn)
	ipClient := ip.NewServiceClient(conn)
	indices, err := findInterfaces(ctx, ifClient)
	if err != nil {
		return err
	}
	clientIndex, ok := indices[clientInterface]
	if !ok {
		return fmt.Errorf("缺少 Goal 001 VPP 接口 %s", clientInterface)
	}
	serverIndex, ok := indices[serverInterface]
	if !ok {
		return fmt.Errorf("缺少 Goal 001 VPP 接口 %s", serverInterface)
	}
	switch action {
	case "setup", "cleanup":
		add := action == "setup"
		for _, item := range []struct {
			name   string
			index  interface_types.InterfaceIndex
			prefix string
		}{{clientInterface, clientIndex, clientGateway}, {serverInterface, serverIndex, serverGateway}} {
			if err := setInterface(ctx, ifClient, ipClient, item.index, item.prefix, add); err != nil {
				return fmt.Errorf("%s %s: %w", action, item.name, err)
			}
			fmt.Printf("%s %s %s\n", action, item.name, item.prefix)
		}
	case "route-add", "route-del":
		if err := setTestRoute(ctx, ipClient, uint32(serverIndex), action == "route-add"); err != nil {
			return fmt.Errorf("%s %s via %s: %w", action, testRoute, testNextHop, err)
		}
		fmt.Printf("%s %s via %s %s\n", action, testRoute, testNextHop, serverInterface)
	}
	return nil
}

func findInterfaces(ctx context.Context, client interfaces.RPCService) (map[string]interface_types.InterfaceIndex, error) {
	stream, err := client.SwInterfaceDump(ctx, &interfaces.SwInterfaceDump{SwIfIndex: interface_types.InterfaceIndex(^uint32(0))})
	if err != nil {
		return nil, fmt.Errorf("SwInterfaceDump: %w", err)
	}
	defer stream.Close()
	indices := make(map[string]interface_types.InterfaceIndex)
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			return indices, nil
		}
		if err != nil {
			return nil, fmt.Errorf("SwInterfaceDump 读取: %w", err)
		}
		indices[item.InterfaceName] = item.SwIfIndex
	}
}

func hasAddress(ctx context.Context, client ip.RPCService, index interface_types.InterfaceIndex, prefix ip_types.Prefix) (bool, error) {
	stream, err := client.IPAddressDump(ctx, &ip.IPAddressDump{SwIfIndex: index})
	if err != nil {
		return false, fmt.Errorf("IPAddressDump: %w", err)
	}
	defer stream.Close()
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("IPAddressDump 读取: %w", err)
		}
		if item.Prefix.String() == prefix.String() {
			return true, nil
		}
	}
}

func setInterface(ctx context.Context, ifClient interfaces.RPCService, ipClient ip.RPCService, index interface_types.InterfaceIndex, cidr string, add bool) error {
	prefix, err := ip_types.ParsePrefix(cidr)
	if err != nil {
		return fmt.Errorf("解析地址 %s: %w", cidr, err)
	}
	exists, err := hasAddress(ctx, ipClient, index, prefix)
	if err != nil {
		return err
	}
	if add && !exists || !add && exists {
		if _, err := ifClient.SwInterfaceAddDelAddress(ctx, &interfaces.SwInterfaceAddDelAddress{SwIfIndex: index, IsAdd: add, Prefix: ip_types.AddressWithPrefix(prefix)}); err != nil {
			return fmt.Errorf("SwInterfaceAddDelAddress: %w", err)
		}
	}
	var flags interface_types.IfStatusFlags
	if add {
		flags = interface_types.IF_STATUS_API_FLAG_ADMIN_UP
	}
	if _, err := ifClient.SwInterfaceSetFlags(ctx, &interfaces.SwInterfaceSetFlags{SwIfIndex: index, Flags: flags}); err != nil {
		return fmt.Errorf("SwInterfaceSetFlags: %w", err)
	}
	return nil
}

func setTestRoute(ctx context.Context, client ip.RPCService, serverIndex uint32, add bool) error {
	prefix, err := ip_types.ParsePrefix(testRoute)
	if err != nil {
		return err
	}
	nh, err := ip_types.ParseIP4Address(testNextHop)
	if err != nil {
		return err
	}
	path := fib_types.FibPath{SwIfIndex: serverIndex, Weight: 1, Proto: fib_types.FIB_API_PATH_NH_PROTO_IP4}
	path.Nh.Address.SetIP4(nh)
	_, err = client.IPRouteAddDel(ctx, &ip.IPRouteAddDel{
		IsAdd: add,
		Route: ip.IPRoute{TableID: 0, Prefix: prefix, Paths: []fib_types.FibPath{path}},
	})
	if err != nil {
		return fmt.Errorf("IPRouteAddDel: %w", err)
	}
	return nil
}
