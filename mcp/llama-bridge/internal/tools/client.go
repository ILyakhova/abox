package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"
)

// The llama.cpp server this bridge talks to. abox serves two of them:
//
//	llama-cpp-embeddings.llama-cpp:8090   standalone Deployment
//	llm-d-embedding.llm-d:8000            the same engine under llm-d
const defaultBaseURL = "http://llama-cpp-embeddings.llama-cpp:8090"

func baseURL() string {
	if v := os.Getenv("LLAMA_BASE_URL"); v != "" {
		return v
	}
	return defaultBaseURL
}

func client() *http.Client {
	secs := 120
	if v := os.Getenv("LLAMA_TIMEOUT_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			secs = n
		}
	}
	return &http.Client{Timeout: time.Duration(secs) * time.Second}
}

// Upstream responses are returned verbatim. The caller is a model, llama.cpp
// already answers in JSON, and reshaping it here would only drop fields.
func do(ctx context.Context, method, path string, body any) (string, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return "", err
		}
		rdr = bytes.NewReader(b)
	}

	req, err := http.NewRequestWithContext(ctx, method, baseURL()+path, rdr)
	if err != nil {
		return "", err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := client().Do(req)
	if err != nil {
		return "", fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	out, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= 400 {
		// 501 here means the server was started with --embeddings and has no
		// generation head; the completion tools cannot work against it.
		return "", fmt.Errorf("%s %s: %s: %s", method, path, resp.Status, out)
	}
	return string(out), nil
}

func get(ctx context.Context, path string) (string, error) {
	return do(ctx, http.MethodGet, path, nil)
}

func post(ctx context.Context, path string, body any) (string, error) {
	return do(ctx, http.MethodPost, path, body)
}
