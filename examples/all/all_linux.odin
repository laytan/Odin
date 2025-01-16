#+build linux
package all

import linux "core:sys/linux"
import uring "core:nbio/uring"

_ :: linux
_ :: uring
