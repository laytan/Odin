#+build darwin, openbsd, freebsd, netbsd
package all

import kqueue "core:sys/kqueue"
import posix  "core:sys/posix"

_ :: kqueue
_ :: posix
_ :: kqueue
