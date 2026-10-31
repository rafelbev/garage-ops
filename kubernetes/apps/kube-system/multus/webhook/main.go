// mac-webhook is a mutating admission webhook that injects a random MAC address
// into each pod's `k8s.v1.cni.cncf.io/networks` annotation. It is used with
// Multus + the `dhcp` CNI IPAM plugin: the DHCP server assigns each pod a random
// IP keyed by the interface's MAC, so each pod needs a unique, stable MAC.
//
// The webhook only acts on pods that carry the `k8s.v1.cni.cncf.io/networks`
// annotation with a `mac` placeholder (e.g. `<MAC>`). For each network entry
// whose `mac` is a placeholder, it generates a random locally-administered
// unicast MAC (02:xx:xx:xx:xx:xx) and replaces the placeholder. Pods without
// the annotation are passed through unchanged.
//
// This is a minimal, dependency-free Go server (no k8s client library): it
// speaks the admission webhook protocol directly over HTTPS.
package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

const (
	listenAddr = ":8443"
	certFile   = "/tls/tls.crt"
	keyFile    = "/tls/tls.key"
)

// --- Admission webhook types (minimal, no k8s client dependency) ---

type AdmissionReview struct {
	APIVersion string           `json:"apiVersion"`
	Kind       string           `json:"kind"`
	Request    *AdmissionRequest `json:"request,omitempty"`
	Response   *AdmissionResponse `json:"response,omitempty"`
}

type AdmissionRequest struct {
	Object rawExtension `json:"object"`
}

type rawExtension struct {
	Raw []byte `json:"raw,omitempty"`
}

type AdmissionResponse struct {
	Allowed   bool          `json:"allowed"`
	PatchType *string       `json:"patchType,omitempty"`
	Patches   []jsonPatchOp `json:"patch,omitempty"`
}

type jsonPatchOp struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

// pod is the minimal pod shape we need (annotation only).
type pod struct {
	Metadata struct {
		Annotations map[string]string `json:"annotations"`
	} `json:"metadata"`
}

// networkEntry is one entry in the `k8s.v1.cni.cncf.io/networks` JSON list.
type networkEntry struct {
	Name      string `json:"name"`
	Interface string `json:"interface,omitempty"`
	MAC       string `json:"mac,omitempty"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", mutate)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "ok")
	})
	fmt.Fprintf(os.Stderr, "mac-webhook listening on %s\n", listenAddr)
	if err := http.ListenAndServeTLS(listenAddr, certFile, keyFile, mux); err != nil {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}

func mutate(w http.ResponseWriter, r *http.Request) {
	var review AdmissionReview
	if err := json.NewDecoder(r.Body).Decode(&review); err != nil {
		http.Error(w, fmt.Sprintf("decode error: %v", err), http.StatusBadRequest)
		return
	}
	if review.Request == nil {
		http.Error(w, "no request", http.StatusBadRequest)
		return
	}

	var p pod
	if err := json.Unmarshal(review.Request.Object.Raw, &p); err != nil {
		// Not a pod we can handle; allow without patch.
		review.Response = &AdmissionResponse{Allowed: true}
		json.NewEncoder(w).Encode(review)
		return
	}

	const annotationKey = "k8s.v1.cni.cncf.io/networks"
	annotation, ok := p.Metadata.Annotations[annotationKey]
	if !ok || annotation == "" {
		// No Multus annotation; pass through.
		review.Response = &AdmissionResponse{Allowed: true}
		json.NewEncoder(w).Encode(review)
		return
	}

	var networks []networkEntry
	if err := json.Unmarshal([]byte(annotation), &networks); err != nil {
		// Malformed annotation; pass through (do not break the pod).
		review.Response = &AdmissionResponse{Allowed: true}
		json.NewEncoder(w).Encode(review)
		return
	}

	changed := false
	for i, net := range networks {
		if isPlaceholder(net.MAC) {
			networks[i].MAC = randomMAC()
			changed = true
		}
	}
	if !changed {
		review.Response = &AdmissionResponse{Allowed: true}
		json.NewEncoder(w).Encode(review)
		return
	}

	updated, err := json.Marshal(networks)
	if err != nil {
		http.Error(w, fmt.Sprintf("marshal error: %v", err), http.StatusInternalServerError)
		return
	}
	// JSON Pointer escaping: `/` in the annotation key -> `~1`.
	escapedKey := strings.ReplaceAll(annotationKey, "/", "~1")
	patch := []jsonPatchOp{
		{Op: "add", Path: "/metadata/annotations/" + escapedKey, Value: string(updated)},
	}
	patchType := "JSONPatch"
	review.Response = &AdmissionResponse{Allowed: true, PatchType: &patchType, Patches: patch}
	review.Kind = "AdmissionReview"
	review.APIVersion = "admission.k8s.io/v1"
	json.NewEncoder(w).Encode(review)
}

// isPlaceholder reports whether the MAC is a placeholder (empty or a `<...>` token).
func isPlaceholder(mac string) bool {
	if mac == "" {
		return true
	}
	return strings.HasPrefix(mac, "<") && strings.HasSuffix(mac, ">")
}

// randomMAC generates a random locally-administered unicast MAC (02:xx:xx:xx:xx:xx).
func randomMAC() string {
	b := make([]byte, 5)
	if _, err := rand.Read(b); err != nil {
		// Fall back to a fixed MAC on error (should not happen).
		b = []byte{0x01, 0x02, 0x03, 0x04, 0x05}
	}
	return fmt.Sprintf("02:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4])
}
