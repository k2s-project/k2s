// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package ssh_test

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/ssh"
	bssh "golang.org/x/crypto/ssh"
	"golang.org/x/term"
)

type sshTestServer struct {
	listener   net.Listener
	cancelChan chan interface{}
	waitGroup  sync.WaitGroup
	sshConfig  *bssh.ServerConfig
}

func TestSshPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ssh pkg Tests", Label("ci", "ssh"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("ssh pkg", func() {
	Describe("CreateKeyPair/Connect", Label("integration"), func() {
		const ipAddress = "0.0.0.0"
		const port = 8022

		var tempKeyFile string
		var tempPubKeyFile string

		BeforeEach(func() {
			tempKeyFile = filepath.Join(GinkgoT().TempDir(), "test-key")
			var err error
			tempPubKeyFile, err = ssh.CreateKeyPair(tempKeyFile, "test-comment")
			Expect(err).ToNot(HaveOccurred())
		})

		When("no SSH server is reachable", func() {
			It("times out within given period", func() {
				clientOptions := ssh.ConnectionOptions{
					IpAddress:         "192.168.1.111",
					Port:              definitions.SSHDefaultPort,
					RemoteUser:        "test-user",
					SshPrivateKeyPath: tempKeyFile,
					Timeout:           time.Second * 1,
				}

				client, err := ssh.Connect(clientOptions)

				Expect(client).To(BeNil())

				Expect(err).To(MatchError(ContainSubstring("failed to connect via SSH")))
			})
		})

		When("SSH server is reachable", func() {
			var sshServer *sshTestServer

			BeforeEach(func() {
				publicKeyBytes, err := os.ReadFile(tempPubKeyFile)
				Expect(err).ToNot(HaveOccurred())

				authorizedKeysMap := map[string]bool{}
				for len(publicKeyBytes) > 0 {
					pubKey, _, _, rest, err := bssh.ParseAuthorizedKey(publicKeyBytes)
					Expect(err).ToNot(HaveOccurred())

					authorizedKeysMap[string(pubKey.Marshal())] = true
					publicKeyBytes = rest
				}

				config := &bssh.ServerConfig{
					PublicKeyCallback: func(c bssh.ConnMetadata, pubKey bssh.PublicKey) (*bssh.Permissions, error) {
						if authorizedKeysMap[string(pubKey.Marshal())] {
							return &bssh.Permissions{
								Extensions: map[string]string{
									"pubkey-fp": bssh.FingerprintSHA256(pubKey),
								},
							}, nil
						}
						return nil, fmt.Errorf("unknown public key for %q", c.User())
					},
				}

				privateKeyBytes, err := os.ReadFile(tempKeyFile)
				Expect(err).ToNot(HaveOccurred())

				private, err := bssh.ParsePrivateKey(privateKeyBytes)
				Expect(err).ToNot(HaveOccurred())

				config.AddHostKey(private)
				listenAdress := fmt.Sprintf("%s:%d", ipAddress, port)

				sshServer = startServer(listenAdress, config)
			})

			AfterEach(func() {
				if sshServer != nil {
					sshServer.stop()
				}
			})

			It("it creates an SSH session", func(ctx context.Context) {
				clientOptions := ssh.ConnectionOptions{
					IpAddress:         ipAddress,
					Port:              port,
					RemoteUser:        "test-user",
					SshPrivateKeyPath: tempKeyFile,
					Timeout:           time.Second * 1,
				}

				client, err := ssh.Connect(clientOptions)
				Expect(err).ToNot(HaveOccurred())

				session, err := client.NewSession()
				Expect(err).ToNot(HaveOccurred())

				Expect(session.Close()).To(Succeed())
				Expect(client.Close()).To(Succeed())
			})
		})
	})

	Describe("DeterminePrivateKeyPath", Label("unit"), func() {
		It("returns the correct path for the private key", func() {
			config := config.NewSshConfig("", "~/relative/dir", "")
			user := users.NewOSUser("", "", "/home/dir")

			sut := ssh.NewKeyPathResolver(config)

			actual := sut.ResolvePrivateKeyPath(user)

			Expect(actual).To(Equal(filepath.Clean("/home/dir/relative/dir/k2s/id_rsa")))
		})
	})
})

func startServer(listenAddress string, config *bssh.ServerConfig) *sshTestServer {
	server := &sshTestServer{
		cancelChan: make(chan any),
		sshConfig:  config,
	}
	listener, err := net.Listen("tcp", listenAddress)
	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Println("SSH server listening on", listenAddress)
	server.listener = listener
	server.waitGroup.Add(1)

	go server.run()

	return server
}

func (server *sshTestServer) stop() {
	GinkgoWriter.Println("Stopping server")

	close(server.cancelChan)
	server.listener.Close()
	server.waitGroup.Wait()
}

func (server *sshTestServer) run() {
	defer server.waitGroup.Done()

	for {
		GinkgoWriter.Println("Waiting for connection")

		connection, err := server.listener.Accept()
		if err != nil {
			select {
			case <-server.cancelChan:
				GinkgoWriter.Println("cancel received")
				return
			default:
				GinkgoWriter.Println("failed to accept connection", err)
			}
		} else {
			server.waitGroup.Add(1)
			go func() {
				server.openSshSession(connection)
				server.waitGroup.Done()
			}()
		}
	}
}

func (server *sshTestServer) openSshSession(connection net.Conn) {
	defer connection.Close()

	GinkgoWriter.Println("Connection accepted, starting SSH session")

	sshConnection, chans, reqs, err := bssh.NewServerConn(connection, server.sshConfig)
	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Printf("Logged in with key %s\n", sshConnection.Permissions.Extensions["pubkey-fp"])

	var waitGroup sync.WaitGroup
	defer waitGroup.Wait()

	waitGroup.Add(1)
	go func() {
		bssh.DiscardRequests(reqs)
		waitGroup.Done()
	}()

	for newChannel := range chans {
		if newChannel.ChannelType() != "session" {
			newChannel.Reject(bssh.UnknownChannelType, "unknown channel type")
			continue
		}
		channel, requests, err := newChannel.Accept()
		Expect(err).ToNot(HaveOccurred())

		waitGroup.Add(1)
		go func(reqChan <-chan *bssh.Request) {
			for req := range reqChan {
				GinkgoWriter.Println("Request type:", req.Type)
				GinkgoWriter.Println("Request payload:", req.Payload)
				GinkgoWriter.Println("Request payload:", string(req.Payload))

				req.Reply(req.Type == "exec", nil) // accept only exec requests, e.g. via "ssh -n <command>"
			}
			waitGroup.Done()
		}(requests)

		term := term.NewTerminal(channel, "test done") // gets closed immediately, no interactive session

		waitGroup.Add(1)
		go func() {
			defer func() {
				channel.Close()
				waitGroup.Done()
			}()
			for {
				line, err := term.ReadLine()
				if err != nil {
					break
				}
				GinkgoWriter.Println(line)
			}
		}()
	}
}
