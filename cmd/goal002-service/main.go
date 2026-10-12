package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"go.fd.io/govpp"
	"go.fd.io/govpp/binapi/cnat"
	"go.fd.io/govpp/binapi/interface_types"
	"go.fd.io/govpp/binapi/ip_types"
)

const (
	testVIP  = "198.18.0.10"
	testPort = 18080
)

func main() {
	apiSocket := flag.String("api-socket", "/run/vpp-goal001/api.sock", "VPP Binary API socket")
	protocol := flag.String("proto", "udp", "udp 或 tcp")
	backends := flag.String("backends", "10.10.2.2,10.10.2.3", "逗号分隔的实验 backend IPv4 地址")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "用法: goal002-service [-proto udp|tcp] [-backends IP,IP] apply|delete|show|sessions|purge")
		os.Exit(2)
	}
	if err := run(*apiSocket, *protocol, *backends, flag.Arg(0)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(socket, protocol, backendList, action string) error {
	proto, err := parseProtocol(protocol)
	if err != nil {
		return err
	}
	if action != "apply" && action != "delete" && action != "show" && action != "sessions" && action != "purge" {
		return fmt.Errorf("未知操作 %q", action)
	}
	conn, err := govpp.Connect(socket)
	if err != nil {
		return fmt.Errorf("连接 VPP Binary API %s: %w", socket, err)
	}
	defer conn.Disconnect()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	client := cnat.NewServiceClient(conn)
	if action == "sessions" {
		return printSessions(ctx, client)
	}
	if action == "purge" {
		return purgeOwnedSessions(ctx, client)
	}
	current, err := findTranslation(ctx, client, proto)
	if err != nil {
		return err
	}
	switch action {
	case "show":
		if current == nil {
			fmt.Printf("%s %s:%d absent\n", protocol, testVIP, testPort)
			return nil
		}
		fmt.Printf("%s %s:%d id=%d lb=%s backends=%d\n", protocol, testVIP, testPort, current.ID, current.LbType, len(current.Paths))
		for _, path := range current.Paths {
			fmt.Printf("  %s:%d\n", path.DstEp.Addr, path.DstEp.Port)
		}
	case "delete":
		if current == nil {
			fmt.Printf("%s %s:%d already absent\n", protocol, testVIP, testPort)
			return nil
		}
		if _, err := client.CnatTranslationDel(ctx, &cnat.CnatTranslationDel{ID: current.ID}); err != nil {
			return fmt.Errorf("CnatTranslationDel id=%d: %w", current.ID, err)
		}
		fmt.Printf("deleted %s %s:%d id=%d\n", protocol, testVIP, testPort, current.ID)
	case "apply":
		paths, err := parseBackends(backendList)
		if err != nil {
			return err
		}
		vip, err := endpoint(testVIP, testPort)
		if err != nil {
			return err
		}
		reply, err := client.CnatTranslationUpdate(ctx, &cnat.CnatTranslationUpdate{Translation: cnat.CnatTranslation{
			Vip: vip, IPProto: proto, IsRealIP: 0,
			LbType: cnat.CNAT_LB_TYPE_MAGLEV, Paths: paths,
		}})
		if err != nil {
			return fmt.Errorf("CnatTranslationUpdate: %w", err)
		}
		fmt.Printf("applied %s %s:%d id=%d backends=%d lb=maglev\n", protocol, testVIP, testPort, reply.ID, len(paths))
	}
	return nil
}

func parseProtocol(s string) (ip_types.IPProto, error) {
	switch s {
	case "udp":
		return ip_types.IP_API_PROTO_UDP, nil
	case "tcp":
		return ip_types.IP_API_PROTO_TCP, nil
	default:
		return 0, fmt.Errorf("协议必须是 udp 或 tcp: %q", s)
	}
}

func endpoint(ip string, port uint16) (cnat.CnatEndpoint, error) {
	addr, err := ip_types.ParseAddress(ip)
	if err != nil || addr.Af != ip_types.ADDRESS_IP4 {
		return cnat.CnatEndpoint{}, fmt.Errorf("无效 IPv4 endpoint %q: %v", ip, err)
	}
	return cnat.CnatEndpoint{Addr: addr, Port: port, SwIfIndex: interface_types.InterfaceIndex(^uint32(0))}, nil
}

func parseBackends(s string) ([]cnat.CnatEndpointTuple, error) {
	var paths []cnat.CnatEndpointTuple
	seen := map[string]bool{}
	for _, raw := range strings.Split(s, ",") {
		ip := strings.TrimSpace(raw)
		if ip != "10.10.2.2" && ip != "10.10.2.3" {
			return nil, fmt.Errorf("backend %q 不在 Goal 002 隔离地址范围", ip)
		}
		if seen[ip] {
			return nil, fmt.Errorf("重复 backend %s", ip)
		}
		seen[ip] = true
		dst, err := endpoint(ip, testPort)
		if err != nil {
			return nil, err
		}
		src, err := endpoint("0.0.0.0", 0)
		if err != nil {
			return nil, err
		}
		paths = append(paths, cnat.CnatEndpointTuple{DstEp: dst, SrcEp: src})
	}
	if len(paths) == 0 {
		return nil, fmt.Errorf("至少需要一个 backend")
	}
	return paths, nil
}

func findTranslation(ctx context.Context, client cnat.RPCService, proto ip_types.IPProto) (*cnat.CnatTranslation, error) {
	stream, err := client.CnatTranslationDump(ctx, &cnat.CnatTranslationDump{})
	if err != nil {
		return nil, fmt.Errorf("CnatTranslationDump: %w", err)
	}
	defer stream.Close()
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			return nil, nil
		}
		if err != nil {
			return nil, fmt.Errorf("CnatTranslationDump 读取: %w", err)
		}
		t := item.Translation
		if t.Vip.Addr.String() == testVIP && t.Vip.Port == testPort && t.IPProto == proto {
			return &t, nil
		}
	}
}

func printSessions(ctx context.Context, client cnat.RPCService) error {
	stream, err := client.CnatSessionDump(ctx, &cnat.CnatSessionDump{})
	if err != nil {
		return fmt.Errorf("CnatSessionDump: %w", err)
	}
	defer stream.Close()
	count := 0
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			fmt.Printf("sessions=%d\n", count)
			return nil
		}
		if err != nil {
			return fmt.Errorf("CnatSessionDump 读取: %w", err)
		}
		s := item.Session
		fmt.Printf("%s:%d -> %s:%d proto=%s new=%s:%d location=%d\n", s.Src.Addr, s.Src.Port, s.Dst.Addr, s.Dst.Port, s.IPProto, s.New.Addr, s.New.Port, s.Location)
		count++
	}
}

// 24.10 的 CnatSessionPurge 同时会删除全部 translation；只在独立实例
// 已无任何 translation，且全部 session 都属于本实验时调用。
func purgeOwnedSessions(ctx context.Context, client cnat.RPCService) error {
	translations, err := client.CnatTranslationDump(ctx, &cnat.CnatTranslationDump{})
	if err != nil {
		return fmt.Errorf("purge 前查询 translation: %w", err)
	}
	defer translations.Close()
	if item, err := translations.Recv(); err != io.EOF {
		if err != nil {
			return fmt.Errorf("purge 前读取 translation: %w", err)
		}
		return fmt.Errorf("拒绝全局 purge：仍有 translation id=%d", item.Translation.ID)
	}
	sessions, err := client.CnatSessionDump(ctx, &cnat.CnatSessionDump{})
	if err != nil {
		return fmt.Errorf("purge 前查询 session: %w", err)
	}
	defer sessions.Close()
	count := 0
	for {
		item, err := sessions.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("purge 前读取 session: %w", err)
		}
		s := item.Session
		src, dst := s.Src.Addr.String(), s.Dst.Addr.String()
		forward := src == "10.10.1.2" && dst == testVIP && s.Dst.Port == testPort
		reverse := (src == "10.10.2.2" || src == "10.10.2.3") && dst == "10.10.1.2" && s.Src.Port == testPort
		if !forward && !reverse {
			return fmt.Errorf("拒绝全局 purge：存在非本实验 session %s:%d -> %s:%d", src, s.Src.Port, dst, s.Dst.Port)
		}
		count++
	}
	if _, err := client.CnatSessionPurge(ctx, &cnat.CnatSessionPurge{}); err != nil {
		return fmt.Errorf("CnatSessionPurge: %w", err)
	}
	fmt.Printf("purged %d Goal 002 sessions\n", count)
	return nil
}
