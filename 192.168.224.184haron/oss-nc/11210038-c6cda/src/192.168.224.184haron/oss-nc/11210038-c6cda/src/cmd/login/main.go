// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"context"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"strings"
	"unsafe"

	hydra "github.com/ory/hydra-client-go"
	"github.com/pkg/errors"
	"github.com/k2s-project/k2s/internal/cli"
	ve "github.com/k2s-project/k2s/internal/version"
	"golang.org/x/sys/windows"
)

const cliName = "login.exe"

var (
	hydraAdminURL string
	port          string
	templates     *template.Template
	logonUserW    = windows.NewLazySystemDLL("advapi32.dll").NewProc("LogonUserW")
)

func init() {
	hydraAdminURL = os.Getenv("HYDRA_ADMIN_URL")
	if hydraAdminURL == "" {
		hydraAdminURL = "http://172.19.1.1:4445" // Default value
	}
	port = os.Getenv("PORT")
	if port == "" {
		port = "3000" // Default port
	}

	currentDir, err := os.Getwd()
	if err != nil {
		log.Fatalf("Error getting current directory: %v", err)
	}
	fmt.Printf("Current working dir: %s\n", currentDir)

	//Parse the templates
	templates, err = template.ParseGlob("templates/*.html")
	if err != nil {
		log.Fatal(errors.Wrap(err, "failed to parse templates"))
	}
}

func main() {
	versionFlag := cli.NewVersionFlag(cliName)
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	http.HandleFunc("/login", loginHandler)
	http.HandleFunc("/consent", consentHandler)
	http.HandleFunc("/logout", logoutHandler)

	fmt.Printf("Listening on http://172.19.1.1:%s\n", port)
	log.Fatal(http.ListenAndServe("172.19.1.1:"+port, nil))
}

func windowsUserLogin(username, password, domain string) bool {
	// log on console user
	fmt.Printf("Attempting login with Username: %s, Domain: %s\n", username, domain)
	pUsername, _ := windows.UTF16PtrFromString(username)
	pDomain, _ := windows.UTF16PtrFromString(domain)
	pPassword, _ := windows.UTF16PtrFromString(password)
	hToken := uintptr(0)
	res, _, err := logonUserW.Call(
		uintptr(unsafe.Pointer(pUsername)),
		uintptr(unsafe.Pointer(pDomain)),
		uintptr(unsafe.Pointer(pPassword)),
		uintptr(2), // LOGON32_LOGON_INTERACTIVE
		uintptr(0), // LOGON32_PROVIDER_DEFAULT
		uintptr(unsafe.Pointer(&hToken)),
	)
	if err != nil {
		fmt.Println(err)
	}
	if res != 0 {
		windows.CloseHandle(windows.Handle(hToken))
	}
	fmt.Printf("Login successfull\n")
	return res != 0
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Printf("Login handler called: %s\n", r.Method)
	adminClient := hydra.NewAPIClient(&hydra.Configuration{
		Servers: []hydra.ServerConfiguration{{URL: hydraAdminURL}},
	})

	if r.Method == "GET" {
		loginChallenge := r.URL.Query().Get("login_challenge")
		if loginChallenge == "" {
			http.Error(w, "Missing login_challenge", http.StatusBadRequest)
			return
		}

		// Fetch login request information from Hydra
		loginRequest, _, err := adminClient.AdminApi.GetLoginRequest(context.Background()).LoginChallenge(loginChallenge).Execute()
		if err != nil {
			http.Error(w, "Error fetching login request", http.StatusInternalServerError)
			log.Println(err)
			return
		}

		// If the user is already authenticated (e.g., has a session), skip the login screen
		//  This part would usually involve checking a session cookie or similar.
		if loginRequest.Skip {
			acceptLogin := hydra.AcceptLoginRequest{
				Subject: loginRequest.Subject,
			}

			completedReq, _, err := adminClient.AdminApi.AcceptLoginRequest(context.Background()).LoginChallenge(loginChallenge).AcceptLoginRequest(acceptLogin).Execute()
			if err != nil {
				http.Error(w, "Error accepting login request", http.StatusInternalServerError)
				log.Println(err)
				return
			}
			http.Redirect(w, r, completedReq.RedirectTo, http.StatusFound)
			return
		}

		// Render the login form
		if err := templates.ExecuteTemplate(w, "login.html", map[string]interface{}{
			"LoginChallenge": loginChallenge,
			"Error":          "", //Initial error state
		}); err != nil {
			http.Error(w, "Error rendering login page", http.StatusInternalServerError)
			return
		}
	} else if r.Method == "POST" {
		r.ParseForm()
		loginChallenge := r.FormValue("login_challenge")
		username := r.FormValue("username")
		password := r.FormValue("password")
		var domain string = ""
		if strings.Contains(username, "\\") {
			parts := strings.SplitN(username, "\\", 2)
			domain = parts[0]
			username = parts[1]
		}
		result := windowsUserLogin(username, password, domain)
		if result {
			// Accept the login request and redirect back to Hydra
			acceptLogin := hydra.AcceptLoginRequest{
				Subject:     username + "@mail.com", //  Set the user ID
				Remember:    hydra.PtrBool(true),    // "Remember" the login (optional)
				RememberFor: hydra.PtrInt64(3600),   // Remember for 1 hour (optional)
			}

			completedReq, _, err := adminClient.AdminApi.AcceptLoginRequest(context.Background()).LoginChallenge(loginChallenge).AcceptLoginRequest(acceptLogin).Execute()
			if err != nil {
				log.Printf("Error accepting login request: %v", err) //Detailed Error Logging
				http.Error(w, "Error accepting login request", http.StatusInternalServerError)
				return
			}
			http.Redirect(w, r, completedReq.RedirectTo, http.StatusFound)

		} else {
			//Render the login form with errors.
			if err := templates.ExecuteTemplate(w, "login.html", map[string]interface{}{
				"LoginChallenge": loginChallenge,
				"Error":          "Invalid username or password",
			}); err != nil {
				http.Error(w, "Error rendering login page", http.StatusInternalServerError)
				return
			}
		}
	}
}

func consentHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Printf("Consent handler called\n")
	adminClient := hydra.NewAPIClient(&hydra.Configuration{
		Servers: []hydra.ServerConfiguration{{URL: hydraAdminURL}},
	})
	consentChallenge := r.URL.Query().Get("consent_challenge")
	// Fetch consent request information from Hydra
	consentRequest, _, err := adminClient.AdminApi.GetConsentRequest(context.Background()).ConsentChallenge(consentChallenge).Execute()
	if err != nil {
		http.Error(w, "Error fetching consent request", http.StatusInternalServerError)
		log.Println(err)
		return
	}

	// If the user has already granted consent, skip the consent screen.
	if *consentRequest.Skip {
		acceptConsent := hydra.AcceptConsentRequest{
			GrantScope:               consentRequest.RequestedScope,               // Grant the requested scopes
			GrantAccessTokenAudience: consentRequest.RequestedAccessTokenAudience, //Grant audiences.
		}
		completedReq, _, err := adminClient.AdminApi.AcceptConsentRequest(context.Background()).ConsentChallenge(consentChallenge).AcceptConsentRequest(acceptConsent).Execute()
		if err != nil {
			http.Error(w, "Error Accepting Consent", http.StatusInternalServerError)
			log.Println(err)
			return
		}
		http.Redirect(w, r, completedReq.RedirectTo, http.StatusFound)
		return
	}

	consentRequest, _, err = adminClient.AdminApi.GetConsentRequest(context.Background()).ConsentChallenge(consentChallenge).Execute()
	if err != nil {
		http.Error(w, "Error getting consent request", http.StatusInternalServerError)
		log.Println(err)
		return
	}

	acceptConsent := hydra.AcceptConsentRequest{
		GrantScope:               consentRequest.RequestedScope,               // Grant the requested scopes
		GrantAccessTokenAudience: consentRequest.RequestedAccessTokenAudience, //Grant audiences.
		Remember:                 hydra.PtrBool(true),
		RememberFor:              hydra.PtrInt64(3600),
		Session: &hydra.ConsentRequestSession{
			AccessToken: map[string]interface{}{
				"email":       *consentRequest.Subject,
				"given_name":  *consentRequest.Subject,
				"family_name": *consentRequest.Subject,
			},
			IdToken: map[string]interface{}{
				"email":       *consentRequest.Subject,
				"given_name":  *consentRequest.Subject,
				"family_name": *consentRequest.Subject,
			},
		},
	}
	completedReq, _, err := adminClient.AdminApi.AcceptConsentRequest(context.Background()).ConsentChallenge(consentChallenge).AcceptConsentRequest(acceptConsent).Execute()

	if err != nil {
		log.Println(err)
		http.Error(w, "Error accepting consent request", http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, completedReq.RedirectTo, http.StatusFound)
}

func logoutHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Printf("Logout handler called\n")
	adminClient := hydra.NewAPIClient(&hydra.Configuration{
		Servers: []hydra.ServerConfiguration{{URL: hydraAdminURL}},
	})

	logoutChallenge := r.URL.Query().Get("logout_challenge")
	if logoutChallenge == "" {
		http.Error(w, "Missing logout_challenge", http.StatusBadRequest)
		return
	}

	// Accept the logout request
	completedReq, _, err := adminClient.AdminApi.AcceptLogoutRequest(context.Background()).LogoutChallenge(logoutChallenge).Execute()
	if err != nil {
		http.Error(w, "Error accepting logout request", http.StatusInternalServerError)
		log.Println(err)
		return
	}

	// Redirect the user to the post-logout URL
	http.Redirect(w, r, completedReq.RedirectTo, http.StatusFound)
}
