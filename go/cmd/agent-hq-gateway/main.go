// Command agent-hq-gateway runs a local OpenAI-compatible gateway on loopback.
//
// It exposes /v1/models and /v1/chat/completions, rewrites only the model field
// of chat requests according to aliases and forwards everything else to the
// configured upstream providers, streaming responses through untouched.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"agent-hq/internal/gateway"
)

const (
	defaultConfigPath = ".agents/config/gateway.json"
	shutdownTimeout   = 10 * time.Second
	readHeaderTimeout = 10 * time.Second
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	flags := flag.NewFlagSet("agent-hq-gateway", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	configPath := flags.String("config", defaultConfigPath, "path to the gateway JSON config")
	flags.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: agent-hq-gateway [-config <path>]\n")
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		// -h/-help is a successful request for usage, not a usage error.
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}

	cfg, err := gateway.LoadConfig(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "agent-hq-gateway:", err)
		return 1
	}
	server, err := gateway.New(cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "agent-hq-gateway:", err)
		return 1
	}

	httpServer := &http.Server{
		Addr:              cfg.Listen,
		Handler:           server.Handler(),
		ReadHeaderTimeout: readHeaderTimeout,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		fmt.Fprintf(os.Stderr, "agent-hq-gateway: listening on http://%s\n", cfg.Listen)
		if serveErr := httpServer.ListenAndServe(); serveErr != nil && serveErr != http.ErrServerClosed {
			errCh <- serveErr
		}
	}()

	select {
	case serveErr := <-errCh:
		fmt.Fprintln(os.Stderr, "agent-hq-gateway:", serveErr)
		return 1
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		fmt.Fprintln(os.Stderr, "agent-hq-gateway: shutdown:", err)
		return 1
	}
	return 0
}
