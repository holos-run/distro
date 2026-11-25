package pins

// cartography's versions.
pins: cartography: {
	approverPolicy: {
		version: "v0.29.0"
		digest:  "sha256:b516dba9e41d8e29957fa8f16479fb109741f7d3f418ef6aa2b47221dfdd5ef3"
	}

	argocd: {
		chart:   "10.11.7"
		version: "v3.5.7"
		digest:  "sha256:16df57da6f223808d204cd94c67c929b931fa01670b91b0b3a2298c4647de0db"
		redis: {
			version: "8.6.4-alpine"
			digest:  "sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"
		}
	}

	cephCSI: {
		version: "3.17.2"
		digest:  "sha256:e93b8b689179bf4f5b501563e85780d2bc127b19bd9bbe36c52a6ceb0c51092d"
	}

	certManager: {
		version: "v1.21.3"
		digests: {
			controller: "sha256:9f4f96a33c7774cef24466fcd85031997531a03a8d117f151126baa8d1290dcc"
			cainjector: "sha256:083d0e906f8eb44e255fe4ff817ae54e49f9ed82e22f1011bb4e9e4f4b8a641f"
			webhook:    "sha256:055ac8e9de6a0ba6763794838fe38944acc650f68ebe1b01dd8be079e580f458"
		}
	}

	cilium: version: "1.20.4"

	cloudNativePG: chart: "0.29.1"

	coredns: {
		chart:   "1.50.2"
		version: "v1.14.7"
		digest:  "sha256:7efd3c635b03efd68c4e8398fc45f0d993d0e9ab016f72c1cefb0fd6d01aa286"
	}

	externalSecrets: version: "2.14.0"

	gatewayAPI: version: "v1.6.3"

	hello: {
		version: "v1.11.0"
		digest:  "sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab"
	}

	holosAuthenticator: {
		version: "0.21.0"
		digest:  "sha256:c5a1838d65e5fadaa48a370056cdc963ba8abe6a5bc19936bc7ab2294590560f"
	}

	holosController: {
		version: "0.22.0"
		digest:  "sha256:117ecfdd80391b77a31a92be16051cda586a2e3d4dcb353ce0bdeff5229ff175"
	}

	istio: {
		version: "1.31.4"
		digests: {
			pilot:         "sha256:2bc9c4190eec5146c6dacb3e2b81fe2752ecd4f5f5198e51fb27ca67b5930312"
			proxyv2:       "sha256:553f3640686d588531426e4c6b6810390b230374b7f83aae65fe4c68efccf1cc"
			"install-cni": "sha256:f80f8bd86001494329d62544da21d75570eef4582f6e95f431296f3bc13b9629"
			ztunnel:       "sha256:7e62e32aebed2cc220aa7a03818b3a0ab6056af462bf3b6a287ea7c6bd3aeec6"
		}
	}

	// The fork's holos-2026-11-25 branch: upstream v1.0.1 and the one commit
	// that builds it against substrate.commit (docs/forks.md).
	kagent: {
		commit:  "c1dbae1b45eefc7d9f8872e660bc5eec6612f09f"
		version: "0.0.0-holos.20261125.c1dbae1"
		charts: {
			crds:   "sha256:953969c4ce578c9fa362bd32c4d2568ad42b30167f1261ae8ff7ff8d539288d8"
			kagent: "sha256:4e38f415d0a7174c3ab37156cc1ba9fc96e1f7fca32bfa7c5dffdeac6ab3b673"
		}
		digests: {
			controller: "sha256:953404be230941ea667307650f7663c49220a89aeaed89790d9c42a9eb3e34c5"
			ui:         "sha256:81456ebc02822a0d678144cfbe3734ab892e4ca3a99ed2b69906bac06f898af3"
		}
		upstream: {
			release: "1.0.1"
			harnesses: {
				kagent: "sha256:d3b1151d39c529a6f921a58a995ff699963012001d2e5075f69bf613abebc24d"
				claude: "sha256:111d28bc8552469b028d91ecd2352c9d44811aba07be12b1e6868db7948f904e"
				codex:  "sha256:6885f229b4ee70c9babf37f89ef5d93438eab049875e5bc129799fef6e4cfd19"
			}
			guest: "sha256:16e84a2285119ce02cc6ba45ea7f68181eb1527335de85477614fb9a6b5ecf03"
		}
		tools: {
			version: "0.3.0"
			digest:  "sha256:cb89eb76216195a90cac73846b447525b6e6e33e45154d1ded9621bf11340315"
		}
	}

	keycloak: {
		version: "26.8.2"
		digests: {
			operator: "sha256:3faeeb34df8da88bb0cacb0a8012f2f517d1b2f3a19e1f8f6884a3c1c67ce7ee"
			server:   "sha256:3879c623248408de29a5303178b5816c77e8dfef3890c361f8c0bbeaa979ba3b"
		}
		postgresql: "18.6-system-trixie"
	}

	kubectl: {
		version: "1.37.1"
		digest:  "sha256:a5d0fbecab3f7b6c2ab7398f1daa73a3e0ed6ece18556d21698233e9e3759cc7"
	}

	localPath: version: "v0.0.37"

	oauth2Proxy: {
		version: "v7.15.6"
		digest:  "sha256:c3415e8660af553f5e18f5d90db050614c02493c0ac6260ac59442f6d9b12048"
	}

	// Planboard v0.0.1, and the agent on kagent.upstream.harnesses.claude.
	planboard: {
		board:  "sha256:b5a72ab690dd0a7e7eed6804765825a846ec04cc54680bdb54322892818dd069"
		agent:  "sha256:b9d207e18537098c064364a1012c5a10a7dd3d7a219a152058ee0a20ad73a2c5"
		plugin: "sha256:f04a6b7f1680999d7eab2a97c4df14b988ead486fcc520db64e779c82a58e4bf"
	}

	quay: {
		version:    "3.17.6"
		digest:     "sha256:e1f7407f90b169247c9a0714ed2cfdd61b24292ed708a12385fd89a762f004a2"
		postgresql: "18.6-system-trixie"
		redis: {
			version: "8.6.8-alpine"
			digest:  "sha256:7d8d9a58ab3ef32025b06c9f9aeb273d0fb82a79f13d63658e7d7e56ee2f032c"
		}
	}

	rustfs: {
		version: "1.0.4"
		busybox: "1.37.0"
		rc:      "v0.1.36"
	}

	secretsManager: {
		version: "0.20.0"
		digest:  "sha256:e33d995aa4f21d4861b5e7715e9674f8bf305278cf359ad32f9ea55d38272d5c"
	}

	// The fork's holos-2026-11-25 branch: upstream main at e54c359a with
	// nothing added, the newest commit kagent builds against (docs/forks.md).
	substrate: {
		commit:  "e54c359a11c9ed30e0fff6bfbaa2ee2665d809b8"
		version: "v0.0.0-holos.20261124.e54c359"
		digests: {
			"ate-idp-server":     "sha256:1f6bb785e7f8c1fd77b893e6952756ba740add971ce53d446fb1626a6146a702"
			ateapi:               "sha256:3d1eca0ec41506f64af2a91970f46bd7961c202fc4185f943f27dc7a786daad4"
			atecontroller:        "sha256:5ed02c1701a130e496e81e3e8a37f95e014f6767771b6847d1857ed440a928e0"
			atelet:               "sha256:d8a889cc247ceb7b76458d9a36146f2b34aac17ac82e8191b6a5442ceb8d7780"
			atenet:               "sha256:783882a760d28a9e6674c74daed960684426e76b0ed1fb0dd2890081a8944702"
			"ateworker-gvisor":   "sha256:0ab15956e9da7ef494c8318ed498885add98309892170e191b6ae8217aba6d21"
			"ateworker-microvm":  "sha256:c694ac3ec823361220b160c69f843bb08cccb2511c54eb4ce536cfc1ea991031"
			"envoy-dataplane":    "sha256:1254a96d87a1a2e216114614606a223a48e387c7d4c5cf6683b13d8f91df007d"
			"kubernetes-secrets": "sha256:3903280cc6024acd1ce8ef247d759dac702a17a5dce1f6b10e714d201005f25d"
			"objectstore-plugin": "sha256:89b60788cf49083a088175adf48749d38c9a847aa4d0bbd9db31ac5b3d977410"
			podcertcontroller:    "sha256:4473113d8da57b74d72c611c57465a618aac78b9b25eeb162e8f2fae6396e08e"
		}
		grpcurl: {
			version: "v1.9.3-alpine"
			digest:  "sha256:4614424ed58e9b9837c48b6b8eadb9ef40491d5af3499bcc8b378e9c64a9e4a9"
		}
		postgresql: "18.6-system-trixie"
	}

	toolhive: {
		version: "0.63.0"
		charts: {
			crds:     "sha256:88d683797fdd9c76cb8171e2c4962bf3b0c43f8da21a6d2ad22cff250eb04163"
			operator: "sha256:710fd900c96c4edb12e3a91b8beeea7709d1034194e31d664aac2fb15eb6d175"
		}
		digests: {
			operator:    "sha256:3cfc741dbb0e37724b4f316ea3e6d0f5a3df36c0ac76cc534952c906525158bd"
			proxyrunner: "sha256:d2bfa6a3c19712eec4c87599696e69ed9234254414754d9dbb3953af383ce4af"
			vmcp:        "sha256:7d07294e3f78995c9f1e7fde7ec34135ad505503b0ab521847625bffe592f72d"
		}
		registryAPI: {
			version: "v1.5.3"
			digest:  "sha256:323652f7bd195a0a6a84815e749f52a809633a07d911580abb2d58945abc78f3"
		}
		everything: {
			version: "2026.8.31"
			digest:  "sha256:cb2e2287d4b6a7d25affee2cde10265bfbf91f9dc38d5cbc8165c6b23fd0cded"
		}
	}

	trustManager: {
		version: "v0.26.0"
		digest:  "sha256:783afe31d39f122a811b96ac3aedab9f358488088df21622ae5b057b4a38b5c2"
		packages: {
			version: "20250419-deb13u1.1"
			digest:  "sha256:477cc69ef6a026b90a6d67d4ac7114735c5f66edf1cc97e68b9da599adf231af"
		}
	}
}
