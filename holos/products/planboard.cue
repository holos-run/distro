package products

// planboard is R.I. Pienaar's Planboard and its agent, on Agent Substrate and
// kagent: a board that serves a planning repository, as an actor in the claim's
// atespace, and an agent that writes to the repository, on kagent's Claude
// harness. So a cluster takes it only with the four components below, and the
// component that renders it is components/product-planboard.
products: planboard: {
	components: ["substrate", "substrate-shim", "kagent-crds", "kagent"]

	#Values: {
		#project: _

		// repo is where the board's plan lives. By convention it is the claim's
		// own repository, on main, with the planning root at the top of the
		// repository, so a binding that follows the convention sets none of it.
		//
		// The patterns are the boundary between the owner and the platform:
		// these strings go into the actor's template, through the environment
		// of a Job that holds Substrate's global owner token, so no quote or
		// space gets past here, whatever becomes of them. url is on github.com because that is the host the actor's
		// egress rule opens, and a path has no segment starting with a dot, so
		// none climbs out of the checkout.
		repo: {
			url: *"https://github.com/holos-run/\(#project)-planning" | =~"^https://github\\.com/[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"
			ref: *"main" | =~"^[A-Za-z0-9][A-Za-z0-9._/-]*$"
			// path is the planning root under the repository's root: empty for
			// the root itself, otherwise a path with a leading slash.
			path: *"" | =~"^(/[A-Za-z0-9_-][A-Za-z0-9._-]*)+$"
		}

		// #projectPattern is the shape of a Planboard project's name, a
		// directory name, as a regular expression. It is a definition, so it is
		// not a value a binding sets, and it is one, because the waypoint's Lua
		// holds the project query parameter to the same shape
		// (components/product-planboard): a request naming a project no
		// binding could list never gets the header the policy reads.
		#projectPattern: "^[A-Za-z0-9][A-Za-z0-9_-]*$"

		// access.viewers.projects are the Planboard projects the claim's viewer
		// group may open, by name, which are directory names. Owners and
		// editors reach them all, so this is the only grant the claim's roles
		// do not already give. The pattern keeps out a wildcard, since a name
		// becomes a value the waypoint's policy matches a header against, and
		// a path segment of its policy's /files/<project>/* and
		// /present/<project>/*.
		access: viewers: projects: [...=~#projectPattern]
	}

	// images are the three images components/product-planboard/Dockerfile
	// builds from Planboard v0.0.1: board, which runs the actor's containers,
	// agent, which is kagent's Claude harness with planboard copied in, and
	// plugin, the planboard plugin as an image volume. Build and push them with
	// README.md, Building the Planboard images.
	images: {
		board:  "sha256:b5a72ab690dd0a7e7eed6804765825a846ec04cc54680bdb54322892818dd069"
		agent:  "sha256:908e537f6f2e3b60ce2504de37ae1ccc9864eba1a82421a7676237d38b317d29"
		plugin: "sha256:f04a6b7f1680999d7eab2a97c4df14b988ead486fcc520db64e779c82a58e4bf"
	}
}
