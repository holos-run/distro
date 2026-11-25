// Package pins is every cluster's versions: one file per cluster, which holds
// the version and digest of everything the platform renders into it. A cluster's
// file is the only place its versions are, so a bump edits the file of the
// cluster it names and moves no other (README.md, Versions).
//
//	// holos/pins/my-cluster.cue
//	package pins
//
//	pins: "my-cluster": {
//		cilium: version: "1.20.4"
//		...
//	}
//
// A component reads its own cluster's as Cluster.pins. Only versions are here:
// the names, ports, policies and values of a component are its own and shared
// by every cluster, and so is why it pins what it does, where that holds on any
// cluster. A file says what holds on its cluster alone.
//
// No pin has a default, and none is shared, though the files repeat each other:
// a default or a shared value is one edit that moves every cluster, which is
// what these files are for not doing.
//
// It is a package of its own, beside projects/, for the reason that one is: CUE
// loads only the root-level holos/*.cue files of package holos as ancestors of
// a component, so clusters.cue imports this package and gives each cluster its
// entry.
package pins

import "strings"

// #Digest is an image or chart digest, the index digest where there is one.
#Digest: =~"^sha256:[0-9a-f]{64}$"

// #Commit is a full commit, never a branch or a tag (docs/forks.md).
#Commit: =~"^[0-9a-f]{40}$"

// #Version is a version as the thing it pins writes it, with its v or without.
// No @ gets past, so a digest has its own field.
#Version: =~"^[0-9A-Za-z][0-9A-Za-z._-]*$"

// #Image is an image's tag, kept for the reader, and the digest that is pulled.
// Its repository is the component's.
#Image: {
	version: #Version
	digest:  #Digest
}

// #Pins is one cluster's versions. It is closed and every pin is required, on a
// cluster that does not take the component too, so one that is missing or
// misspelt fails cue vet with the cluster and the pin in the message:
// pinned."marina.cilium.version". A pin only some clusters have, such as the digest
// of an image a newer Substrate commit adds, is an optional field until every
// cluster has it, and the component reads it only where it is set.
#Pins: {
	// approverPolicy is the chart's version and its image's.
	approverPolicy: #Image

	// argocd is Argo CD's: chart is argo-helm's, version and digest the image
	// the chart runs, and redis the chart's Redis.
	argocd: {
		#Image
		chart: #Version
		redis: #Image
	}

	// cephCSI is the chart's version, the driver's, and its image's digest.
	cephCSI: #Image

	// certManager is the chart's version, the images', and their digests.
	certManager: {
		version: #Version
		digests: {
			controller: #Digest
			cainjector: #Digest
			webhook:    #Digest
		}
	}

	// cilium is the chart's version, the agent's.
	cilium: version: #Version

	// cloudNativePG is the chart's version, which is not the operator's.
	cloudNativePG: chart: #Version

	// coredns is CoreDNS: chart is its chart, and version and digest the image.
	coredns: {
		#Image
		chart: #Version
	}

	// externalSecrets is the chart's version, the operator's.
	externalSecrets: version: #Version

	// gatewayAPI is the release whose CRDs components/gateway-api vendors.
	gatewayAPI: version: #Version

	// hello is the whoami image's.
	hello: #Image

	// holosAuthenticator and holosController are the aavis-ops releases the
	// platform authenticator and the platform controller run, and whose CRDs
	// their components vendor.
	holosAuthenticator: #Image
	holosController:    #Image

	// istio is the release of the four charts and of the images.
	istio: {
		version: #Version
		digests: {
			pilot:         #Digest
			proxyv2:       #Digest
			"install-cni": #Digest
			ztunnel:       #Digest
		}
	}

	// kagent is the holos-run fork's commit, the version its charts and images
	// are published under, and their digests, which components read as Kagent.
	// It moves together with substrate, whose commit the fork builds against.
	kagent: {
		commit:  #Commit
		version: #Version
		charts: {
			crds:   #Digest
			kagent: #Digest
		}
		digests: {
			controller: #Digest
			ui:         #Digest
		}
		// upstream is the kagent-dev release the agents' images are from.
		// harnesses.claude is the base of planboard.agent, which is rebuilt
		// when it moves (README.md, Building the Planboard images).
		upstream: {
			release: #Version
			harnesses: {
				kagent: #Digest
				claude: #Digest
				codex:  #Digest
			}
			guest: #Digest
		}
		// tools is the tool server's image.
		tools: #Image
	}

	// keycloak is the operator's release and the server's, and postgresql the
	// tag of its database's image.
	keycloak: {
		version: #Version
		digests: {
			operator: #Digest
			server:   #Digest
		}
		postgresql: #Version
	}

	// kubectl is alpine/kubectl's, which keycloak-realm's Job runs.
	kubectl: #Image

	// localPath is the release whose manifest components/local-path vendors.
	localPath: version: #Version

	// oauth2Proxy is the login's in front of kagent's UI and every board.
	oauth2Proxy: #Image

	// planboard is the digests of the Planboard product's images, which
	// components/product-planboard/Dockerfile builds (README.md, Building the
	// Planboard images). A digest alone: the registry is the cluster's Quay and
	// the organization the claim's. A product of the collection (products/) has
	// its images here under its name, so no binding can run an image the
	// cluster does not pin.
	planboard: {
		board:  #Digest
		agent:  #Digest
		plugin: #Digest
	}

	// quay is Quay's release, its Redis, and the tag of its database's image.
	quay: {
		#Image
		postgresql: #Version
		redis:      #Image
	}

	// rustfs is the chart's version, the server's, the init container's busybox
	// tag, and the tag of rc, the client the register Job runs.
	rustfs: {
		version: #Version
		busybox: #Version
		rc:      #Version
	}

	// secretsManager is the holos-run/secrets-manager release.
	secretsManager: #Image

	// substrate is the holos-run fork's commit, whose submodule,
	// vendor/substrate-<commit>, the substrate component renders from, the
	// version its images are published under, and their digests, which
	// components read as Substrate.
	substrate: {
		commit:  #Commit
		version: #Version
		digests: {
			"ate-idp-server":     #Digest
			ateapi:               #Digest
			atecontroller:        #Digest
			atelet:               #Digest
			atenet:               #Digest
			"ateworker-gvisor":   #Digest
			"ateworker-microvm":  #Digest
			"envoy-dataplane":    #Digest
			"kubernetes-secrets": #Digest
			"objectstore-plugin": #Digest
			podcertcontroller:    #Digest
		}
		// grpcurl is the image of every Job that calls the API.
		grpcurl: #Image
		// postgresql is the tag of substrate-db's image.
		postgresql: #Version
	}

	// toolhive is the release of the two charts and of three images, and the
	// registry API and the MCP server everything, with versions of their own.
	toolhive: {
		version: #Version
		charts: {
			crds:     #Digest
			operator: #Digest
		}
		digests: {
			operator:    #Digest
			proxyrunner: #Digest
			vmcp:        #Digest
		}
		registryAPI: #Image
		everything:  #Image
	}

	// trustManager is the chart's version, its image's, and the public CA
	// package its Bundles can include.
	trustManager: {
		#Image
		packages: #Image
	}
}

// pins is the collection, keyed by cluster.
pins: [string]: #Pins

// pinned has no entry, since every cluster sets every pin: an entry for one
// left unset conflicts here, which is what names the cluster and the pin. CUE's
// own required fields do not, since cue vet reports a field left unset as an
// incomplete instance, unnamed. A pin is unset when it still takes a value of
// its shape that no pin has.
pinned: [string]: "set in the cluster's file"

let Unset = "unset" | "sha256:\(strings.Repeat("0", 64))" | strings.Repeat("0", 40)

for C, P in pins for A, PA in P {
	if (PA & Unset) != _|_ {
		pinned: "\(C).\(A)": "unset"
	}
	if (PA & {...}) != _|_ for B, PB in PA {
		if (PB & Unset) != _|_ {
			pinned: "\(C).\(A).\(B)": "unset"
		}
		if (PB & {...}) != _|_ for D, PD in PB {
			if (PD & Unset) != _|_ {
				pinned: "\(C).\(A).\(B).\(D)": "unset"
			}
			if (PD & {...}) != _|_ for E, PE in PD {
				if (PE & Unset) != _|_ {
					pinned: "\(C).\(A).\(B).\(D).\(E)": "unset"
				}
			}
		}
	}
}
