@extern(embed)
package holos

// ArgoCD names the platform's Argo CD: where it runs, the git repository and
// branch it syncs from, the AppProject every platform Application belongs to,
// and the keys a commit on that branch must be signed with. The argocd
// component installs it; argocd-apps renders the AppProject and an
// Application per component in the registry (registry.cue).
ArgoCD: {
	namespace: "argocd"

	// repoURL is read anonymously: holos-run/distro is public, so there is
	// no deploy key or repository Secret.
	repoURL:        "https://github.com/holos-run/distro.git"
	targetRevision: "main"

	// project is the AppProject of every platform Application.
	project: "platform"

	// signingKeys are the GnuPG keys a commit must be signed with for Argo CD
	// to sync it (interview Q39): the project's signatureKeys, and Argo CD's
	// keyring, keyed by long key ID. Argo CD verifies the commit at the
	// branch's head, which is a merge commit made in GitHub's UI and signed
	// with GitHub's web-flow key, or a commit pushed straight to main and
	// signed by its author. The armored public keys are in signing-keys/.
	signingKeys: [ID=string]: {
		id:        ID
		owner:     string
		publicKey: string
	}
	signingKeys: {
		"7716CCA9F8F7BE25": {
			owner:     "Jeff McCune <jeff@openinfrastructure.co>"
			publicKey: _ @embed(file="signing-keys/7716CCA9F8F7BE25.asc", type=text)
		}
		// GitHub's current web-flow key, from https://github.com/web-flow.gpg,
		// which also holds the expired 4AEE18F83AFDEB23.
		"B5690EEEBB952194": {
			owner:     "GitHub (web-flow commit signing) <noreply@github.com>"
			publicKey: _ @embed(file="signing-keys/B5690EEEBB952194.asc", type=text)
		}
	}
}
