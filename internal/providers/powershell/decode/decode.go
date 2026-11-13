// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package decode

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"fmt"
	"io"
	"log/slog"
	"strings"
)

const (
	separator     = "#"
	marker        = "#pm#"
	segmentsCount = 4
)

func IsEncodedMessage(message string) bool {
	return strings.HasPrefix(message, marker)
}

func DecodeMessages(messages []string, targetType string) ([]byte, error) {
	if len(messages) == 0 {
		return nil, fmt.Errorf("no messages to decode (targetType: %s)", targetType)
	}

	slog.Debug("Decoding structured messages", "count", len(messages), "targetType", targetType)

	// Group messages by independent payloads vs. chunked payloads.
	// Each Send-ToCli invocation produces one or more chunks that together form
	// a single complete base64+gzip payload. When a script erroneously calls
	// Send-ToCli multiple times, the decoder receives chunks from multiple
	// independent payloads concatenated. Detect this by trying the full
	// concatenation first; on failure, fall back to decoding only the last
	// contiguous group of messages (the final Send-ToCli result).
	var buffer bytes.Buffer
	for _, message := range messages {
		payload, err := extractPayload(message, targetType)
		if err != nil {
			return nil, fmt.Errorf("failed to extract payload from message: %w", err)
		}

		_, err = buffer.Write(payload)
		if err != nil {
			return nil, fmt.Errorf("failed to write payload to buffer: %w", err)
		}
	}

	result, err := decodeAndUncompress(buffer.Bytes())
	if err == nil {
		return result, nil
	}

	// Full concatenation failed — try fallback to last message only
	if len(messages) > 1 {
		slog.Warn("Decoding all messages failed, attempting fallback to last message",
			"error", err, "totalMessages", len(messages))

		lastPayload, extractErr := extractPayload(messages[len(messages)-1], targetType)
		if extractErr == nil {
			result, fallbackErr := decodeAndUncompress(lastPayload)
			if fallbackErr == nil {
				slog.Warn("Fallback to last message succeeded; earlier messages were discarded",
					"discardedCount", len(messages)-1)
				return result, nil
			}
			slog.Debug("Fallback to last message also failed", "error", fallbackErr)
		}
	}

	return nil, fmt.Errorf("failed to decode messages: %w", err)
}

func extractPayload(message string, targetType string) ([]byte, error) {
	segments := strings.Split(message, separator)

	if len(segments) != segmentsCount {
		truncated := message
		if len(truncated) > 100 {
			truncated = truncated[:100] + "..."
		}
		return nil, fmt.Errorf("message malformed: found '%d' segments instead of '%d' in message: %s", len(segments), segmentsCount, truncated)
	}

	actualType := segments[2]

	if actualType != targetType {
		return nil, fmt.Errorf("message type mismatch: Expected '%s', but got '%s'", targetType, actualType)
	}

	return []byte(segments[3]), nil
}

func decodeAndUncompress(data []byte) ([]byte, error) {
	decodedBytes, err := decodeBase64(data)
	if err != nil {
		return nil, err
	}

	return uncompress(decodedBytes)
}

func decodeBase64(data []byte) ([]byte, error) {
	decodedBytes := make([]byte, base64.StdEncoding.DecodedLen(len(data)))

	decodedLen, err := base64.StdEncoding.Decode(decodedBytes, data)
	if err != nil {
		return nil, err
	}

	return decodedBytes[:decodedLen], nil
}

func uncompress(data []byte) ([]byte, error) {
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}

	return io.ReadAll(reader)
}
