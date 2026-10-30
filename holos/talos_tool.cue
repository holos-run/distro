package holos

import (
	pathpkg "path"
	"tool/file"
)

// Patches is the package's talos (talos.cue); inside command: talos the name
// would be the command itself.
let Patches = talos

// `cue cmd talos`, run in this directory, writes every cluster's Talos patches
// (talos.cue) to providers/talos/clusters/<cluster>/. Run it with
// every render (README.md, "Render") and commit the result.
command: talos: {
	for K, T in Patches {
		(K): {
			mkdir: file.MkdirAll & {path: pathpkg.Dir(T.file, pathpkg.Unix)}
			write: file.Create & {
				$after:   mkdir
				filename: T.file
				contents: T.text
			}
		}
	}
}
