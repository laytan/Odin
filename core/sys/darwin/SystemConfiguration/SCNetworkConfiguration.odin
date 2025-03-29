package SystemConfiguration

import CF "core:sys/darwin/CoreFoundation"

foreign import SystemConfiguration "system:SystemConfiguration.framework"

NetworkInterfaceRef :: distinct rawptr

@(link_prefix="SC")
foreign SystemConfiguration {
	// Returns all network capable interfaces on the system.
	NetworkInterfaceCopyAll :: proc() -> CF.ArrayRef ---

	NetworkInterfaceGetBSDName               :: proc(interface: NetworkInterfaceRef) -> CF.String ---
	NetworkInterfaceGetLocalizedDisplayName  :: proc(interface: NetworkInterfaceRef) -> CF.String ---
	NetworkInterfaceGetHardwareAddressString :: proc(interface: NetworkInterfaceRef) -> CF.String ---
	NetworkInterfaceGetInterfaceType         :: proc(interface: NetworkInterfaceRef) -> CF.String ---
}
