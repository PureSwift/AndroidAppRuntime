@_exported import AndroidHost
import AndroidHostBluetooth
import AndroidHostDefaults
import AndroidHostDevice
import AndroidHostFiles
import AndroidHostFormatting
import AndroidHostGraphics
import AndroidHostLocation
import AndroidHostMotion
import AndroidHostNFC
import AndroidHostNetworking
import AndroidHostUI
import AndroidHostWebKit

/// Every module this host has: what `libapp.so` registers and what the
/// packager checks apps against, from one list.
public enum AndroidHostModules {

    nonisolated(unsafe) public static let all: [any HostModule.Type] = [
        AndroidHostUI.self,
        AndroidHostDevice.self,
        AndroidHostFormatting.self,
        AndroidHostLocation.self,
        AndroidHostNetworking.self,
        AndroidHostBluetooth.self,
        AndroidHostMotion.self,
        AndroidHostNFC.self,
        AndroidHostGraphics.self,
        AndroidHostWebKit.self,
        AndroidHostFiles.self,
        AndroidHostDefaults.self,
    ]
}
