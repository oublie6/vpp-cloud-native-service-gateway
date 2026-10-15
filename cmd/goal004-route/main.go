package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/netip"
	"os"
	"time"

	"go.fd.io/govpp"
	"go.fd.io/govpp/binapi/cnat"
	"go.fd.io/govpp/binapi/fib_types"
	interfaces "go.fd.io/govpp/binapi/interface"
	"go.fd.io/govpp/binapi/ip"
	"go.fd.io/govpp/binapi/ip_types"
)

const (
	apiSocket     = "/run/vpp-goal001/api.sock"
	marker        = "/run/vpp-goal001/goal004-owned"
	defaultPrefix = "10.10.4.2/32"
	nextHop       = "10.10.2.2"
	iface         = "tap102"
)

func main() {
	requestedPrefix := flag.String("prefix", defaultPrefix, "Goal 004 backend /32；默认逻辑远端，或当前美国节点 Pod CIDR")
	flag.Parse()
	if flag.NArg() != 1 || (flag.Arg(0) != "add" && flag.Arg(0) != "del" && flag.Arg(0) != "inspect") {
		fmt.Fprintln(os.Stderr, "用法: goal004-route [-prefix BACKEND/32] add|del|inspect")
		os.Exit(2)
	}
	prefix, err := netip.ParsePrefix(*requestedPrefix)
	if err != nil || !prefix.Addr().Is4() || prefix.Bits() != 32 ||
		(prefix.String() != defaultPrefix && !netip.MustParsePrefix("10.244.0.0/24").Contains(prefix.Addr())) {
		fmt.Fprintf(os.Stderr, "拒绝非 Goal 004 backend /32: %q\n", *requestedPrefix)
		os.Exit(2)
	}
	if flag.Arg(0) != "inspect" {
		if _, err := os.Stat(marker); err != nil {
			fmt.Fprintf(os.Stderr, "Goal 004 ownership marker %s 不可用: %v\n", marker, err)
			os.Exit(1)
		}
	}
	if err := run(flag.Arg(0), prefix.String(), prefix.Addr().String()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(action, prefix, backendIP string) error {
	conn, err := govpp.Connect(apiSocket)
	if err != nil {
		return fmt.Errorf("连接 VPP Binary API: %w", err)
	}
	defer conn.Disconnect()
	channel, err := conn.NewAPIChannel()
	if err != nil {
		return fmt.Errorf("创建 GoVPP channel: %w", err)
	}
	err = channel.CheckCompatiblity(&interfaces.SwInterfaceDump{}, &interfaces.SwInterfaceDetails{},
		&ip.IPRouteDump{}, &ip.IPRouteDetails{}, &ip.IPRouteAddDel{}, &ip.IPRouteAddDelReply{},
		&cnat.CnatTranslationDump{}, &cnat.CnatTranslationDetails{})
	channel.Close()
	if err != nil {
		return fmt.Errorf("FIB Binary API schema 不兼容: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	ipClient := ip.NewServiceClient(conn)
	ifIndex, err := findInterface(ctx, interfaces.NewServiceClient(conn))
	if err != nil {
		return err
	}
	existing, err := findRoute(ctx, ipClient, prefix)
	if err != nil {
		return err
	}
	if existing != nil && !ownedPath(existing, ifIndex) {
		if action != "add" || !dropOnly(existing) {
			return fmt.Errorf("%s 已有非 Goal 004 路由，拒绝修改: %+v", prefix, existing.Paths)
		}
		managed, err := hasManagedBackend(ctx, cnat.NewServiceClient(conn), backendIP)
		if err != nil {
			return err
		}
		if !managed {
			return fmt.Errorf("%s 的 drop route 不属于 Goal 004 CNAT backend，拒绝覆盖", prefix)
		}
	}
	switch action {
	case "add":
		if existing == nil || !ownedPath(existing, ifIndex) {
			if err := updateRoute(ctx, ipClient, ifIndex, prefix, true); err != nil {
				return err
			}
		}
	case "del":
		if existing != nil {
			if err := updateRoute(ctx, ipClient, ifIndex, prefix, false); err != nil {
				return err
			}
		}
	}
	observed, err := findRoute(ctx, ipClient, prefix)
	if err != nil {
		return fmt.Errorf("操作后复查 FIB: %w", err)
	}
	if action == "del" && observed != nil {
		return fmt.Errorf("%s 删除后仍存在", prefix)
	}
	if action != "del" && (observed == nil || !ownedPath(observed, ifIndex)) && action == "add" {
		return fmt.Errorf("%s 添加后未观察到预期 next-hop", prefix)
	}
	if observed == nil {
		fmt.Printf("route %s absent\n", prefix)
	} else {
		fmt.Printf("route %s via %s %s present\n", prefix, nextHop, iface)
	}
	return nil
}

func findInterface(ctx context.Context, client interfaces.RPCService) (uint32, error) {
	stream, err := client.SwInterfaceDump(ctx, &interfaces.SwInterfaceDump{})
	if err != nil {
		return 0, fmt.Errorf("SwInterfaceDump: %w", err)
	}
	defer stream.Close()
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			return 0, fmt.Errorf("VPP interface %s 不存在", iface)
		}
		if err != nil {
			return 0, fmt.Errorf("SwInterfaceDump 读取: %w", err)
		}
		if item.InterfaceName == iface {
			return uint32(item.SwIfIndex), nil
		}
	}
}

func findRoute(ctx context.Context, client ip.RPCService, prefix string) (*ip.IPRoute, error) {
	stream, err := client.IPRouteDump(ctx, &ip.IPRouteDump{Table: ip.IPTable{TableID: 0}})
	if err != nil {
		return nil, fmt.Errorf("IPRouteDump: %w", err)
	}
	defer stream.Close()
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			return nil, nil
		}
		if err != nil {
			return nil, fmt.Errorf("IPRouteDump 读取: %w", err)
		}
		if item.Route.Prefix.String() == prefix {
			return &item.Route, nil
		}
	}
}

func ownedPath(route *ip.IPRoute, ifIndex uint32) bool {
	return len(route.Paths) == 1 && route.Paths[0].SwIfIndex == ifIndex &&
		route.Paths[0].Nh.Address.GetIP4().String() == nextHop
}

// CNAT 在 backend 尚不可达时可能先建立一个 drop FIB entry；Goal 004
// 随后通过 Binary API 添加明确的 next-hop，使该 entry 解析为完整 adjacency。
func dropOnly(route *ip.IPRoute) bool {
	return len(route.Paths) == 1 && route.Paths[0].Type == fib_types.FIB_API_PATH_TYPE_DROP &&
		route.Paths[0].SwIfIndex == ^uint32(0)
}

func hasManagedBackend(ctx context.Context, client cnat.RPCService, backendIP string) (bool, error) {
	stream, err := client.CnatTranslationDump(ctx, &cnat.CnatTranslationDump{})
	if err != nil {
		return false, fmt.Errorf("确认 CNAT backend: %w", err)
	}
	defer stream.Close()
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("读取 CNAT backend: %w", err)
		}
		translation := item.Translation
		if translation.Vip.Addr.String() != "198.19.0.20" || translation.Vip.Port != 18080 {
			continue
		}
		for _, path := range translation.Paths {
			if path.DstEp.Addr.String() == backendIP && path.DstEp.Port == 18080 {
				return true, nil
			}
		}
	}
}

func updateRoute(ctx context.Context, client ip.RPCService, ifIndex uint32, prefix string, add bool) error {
	destination, err := ip_types.ParsePrefix(prefix)
	if err != nil {
		return err
	}
	nh, err := ip_types.ParseIP4Address(nextHop)
	if err != nil {
		return err
	}
	path := fib_types.FibPath{SwIfIndex: ifIndex, Weight: 1, Proto: fib_types.FIB_API_PATH_NH_PROTO_IP4}
	path.Nh.Address.SetIP4(nh)
	_, err = client.IPRouteAddDel(ctx, &ip.IPRouteAddDel{IsAdd: add,
		Route: ip.IPRoute{TableID: 0, Prefix: destination, Paths: []fib_types.FibPath{path}}})
	if err != nil {
		return fmt.Errorf("IPRouteAddDel %s via %s: %w", prefix, nextHop, err)
	}
	return nil
}
