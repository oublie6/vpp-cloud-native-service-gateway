package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	"go.fd.io/govpp"
	"go.fd.io/govpp/binapi/cnat"
)

// VPP 24.10 的 purge 会清空全部 CNAT translation 与 session；先确认全局无
// translation，且每条 session 都属于 Goal 004 的独立 VIP/地址，再调用。
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	conn, err := govpp.Connect("/run/vpp-goal001/api.sock")
	if err != nil {
		return fmt.Errorf("连接 VPP Binary API: %w", err)
	}
	defer conn.Disconnect()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	client := cnat.NewServiceClient(conn)
	translations, err := client.CnatTranslationDump(ctx, &cnat.CnatTranslationDump{})
	if err != nil {
		return fmt.Errorf("CnatTranslationDump: %w", err)
	}
	defer translations.Close()
	if item, err := translations.Recv(); err != io.EOF {
		if err != nil {
			return fmt.Errorf("CnatTranslationDump 读取: %w", err)
		}
		return fmt.Errorf("拒绝 purge：仍有 translation id=%d", item.Translation.ID)
	}
	sessions, err := client.CnatSessionDump(ctx, &cnat.CnatSessionDump{})
	if err != nil {
		return fmt.Errorf("CnatSessionDump: %w", err)
	}
	defer sessions.Close()
	count := 0
	for {
		item, err := sessions.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("CnatSessionDump 读取: %w", err)
		}
		s := item.Session
		src, dst := s.Src.Addr.String(), s.Dst.Addr.String()
		forward := src == "10.10.1.2" && dst == "198.19.0.20" && s.Dst.Port == 18080
		reverse := (src == "10.10.2.2" || src == "10.10.4.2") && dst == "10.10.1.2" && s.Src.Port == 18080
		if !forward && !reverse {
			return fmt.Errorf("拒绝 purge：存在非 Goal 004 session %s:%d -> %s:%d", src, s.Src.Port, dst, s.Dst.Port)
		}
		count++
	}
	if _, err := client.CnatSessionPurge(ctx, &cnat.CnatSessionPurge{}); err != nil {
		return fmt.Errorf("CnatSessionPurge: %w", err)
	}
	fmt.Printf("purged %d Goal 004 sessions\n", count)
	return nil
}
