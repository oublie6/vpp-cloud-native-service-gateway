package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"go.fd.io/govpp"
	"go.fd.io/govpp/adapter/statsclient"
	"go.fd.io/govpp/api"
	"go.fd.io/govpp/binapi/cnat"
	interfaces "go.fd.io/govpp/binapi/interface"
	"go.fd.io/govpp/binapi/interface_types"
	"go.fd.io/govpp/binapi/ip"
	"go.fd.io/govpp/core"
)

func main() {
	apiSocket := flag.String("api-socket", "/run/vpp-goal001/api.sock", "VPP Binary API socket")
	statsSocket := flag.String("stats-socket", "/run/vpp-goal001/stats.sock", "VPP Stats API socket")
	flag.Parse()
	if err := inspect(*apiSocket, *statsSocket); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func inspect(apiSocket, statsSocket string) error {
	conn, err := govpp.Connect(apiSocket)
	if err != nil {
		return fmt.Errorf("连接 Binary API %s: %w", apiSocket, err)
	}
	defer conn.Disconnect()

	ch, err := conn.NewAPIChannel()
	if err != nil {
		return fmt.Errorf("创建 Binary API channel: %w", err)
	}
	defer ch.Close()
	if err := ch.CheckCompatiblity(
		&interfaces.SwInterfaceDump{}, &interfaces.SwInterfaceDetails{},
		&interfaces.SwInterfaceAddDelAddress{}, &interfaces.SwInterfaceAddDelAddressReply{},
		&interfaces.SwInterfaceSetFlags{}, &interfaces.SwInterfaceSetFlagsReply{},
		&ip.IPRouteAddDel{}, &ip.IPRouteAddDelReply{},
		&ip.IPRouteDump{}, &ip.IPRouteDetails{},
		&cnat.CnatTranslationUpdate{}, &cnat.CnatTranslationUpdateReply{},
		&cnat.CnatTranslationDel{}, &cnat.CnatTranslationDelReply{},
		&cnat.CnatTranslationDump{}, &cnat.CnatTranslationDetails{},
		&cnat.CnatSessionDump{}, &cnat.CnatSessionDetails{},
	); err != nil {
		return fmt.Errorf("VPP 24.10 与 GoVPP message CRC 不兼容: %w", err)
	}
	fmt.Println("Binary API message/CRC: interface, FIB, CNAT compatible")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ifCount, err := countInterfaces(ctx, interfaces.NewServiceClient(conn))
	if err != nil {
		return err
	}
	routeCount, err := countRoutes(ctx, ip.NewServiceClient(conn))
	if err != nil {
		return err
	}
	translationCount, sessionCount, err := countCNAT(ctx, cnat.NewServiceClient(conn))
	if err != nil {
		return err
	}
	fmt.Printf("Binary API dumps: interfaces=%d IPv4 routes=%d CNAT translations=%d sessions=%d\n", ifCount, routeCount, translationCount, sessionCount)

	stats, err := core.ConnectStats(statsclient.NewStatsClient(statsSocket))
	if err != nil {
		return fmt.Errorf("连接 Stats API %s: %w", statsSocket, err)
	}
	defer stats.Disconnect()
	var ifaceStats api.InterfaceStats
	if err := stats.GetInterfaceStats(&ifaceStats); err != nil {
		return fmt.Errorf("读取接口 Stats API: %w", err)
	}
	for _, item := range ifaceStats.Interfaces {
		if item.InterfaceName != "" {
			fmt.Printf("Stats API: %s index=%d rx=%d tx=%d rx_errors=%d tx_errors=%d\n", item.InterfaceName, item.InterfaceIndex, item.Rx.Packets, item.Tx.Packets, item.RxErrors, item.TxErrors)
		}
	}
	return nil
}

func countInterfaces(ctx context.Context, client interfaces.RPCService) (int, error) {
	stream, err := client.SwInterfaceDump(ctx, &interfaces.SwInterfaceDump{SwIfIndex: interface_types.InterfaceIndex(^uint32(0))})
	if err != nil {
		return 0, fmt.Errorf("SwInterfaceDump: %w", err)
	}
	defer stream.Close()
	count := 0
	for {
		_, err := stream.Recv()
		if err == io.EOF {
			return count, nil
		}
		if err != nil {
			return 0, fmt.Errorf("SwInterfaceDump 读取: %w", err)
		}
		count++
	}
}

func countRoutes(ctx context.Context, client ip.RPCService) (int, error) {
	stream, err := client.IPRouteDump(ctx, &ip.IPRouteDump{Table: ip.IPTable{TableID: 0}})
	if err != nil {
		return 0, fmt.Errorf("IPRouteDump: %w", err)
	}
	defer stream.Close()
	count := 0
	for {
		_, err := stream.Recv()
		if err == io.EOF {
			return count, nil
		}
		if err != nil {
			return 0, fmt.Errorf("IPRouteDump 读取: %w", err)
		}
		count++
	}
}

func countCNAT(ctx context.Context, client cnat.RPCService) (int, int, error) {
	translations, err := client.CnatTranslationDump(ctx, &cnat.CnatTranslationDump{})
	if err != nil {
		return 0, 0, fmt.Errorf("CnatTranslationDump: %w", err)
	}
	defer translations.Close()
	translationCount := 0
	for {
		_, err := translations.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, 0, fmt.Errorf("CnatTranslationDump 读取: %w", err)
		}
		translationCount++
	}
	sessions, err := client.CnatSessionDump(ctx, &cnat.CnatSessionDump{})
	if err != nil {
		return 0, 0, fmt.Errorf("CnatSessionDump: %w", err)
	}
	defer sessions.Close()
	sessionCount := 0
	for {
		_, err := sessions.Recv()
		if err == io.EOF {
			return translationCount, sessionCount, nil
		}
		if err != nil {
			return 0, 0, fmt.Errorf("CnatSessionDump 读取: %w", err)
		}
		sessionCount++
	}
}
