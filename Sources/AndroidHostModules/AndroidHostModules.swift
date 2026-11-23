@_exported import AndroidHost
import AndroidHostAuthentication
import AndroidHostBackgroundTasks
import AndroidHostBluetooth
import AndroidHostClipboard
import AndroidHostDefaults
import AndroidHostDevice
import AndroidHostDocuments
import AndroidHostFiles
import AndroidHostFormatting
import AndroidHostGraphics
import AndroidHostLocation
import AndroidHostMedia
import AndroidHostModelStore
import AndroidHostMotion
import AndroidHostNFC
import AndroidHostNotifications
import AndroidHostNetworking
import AndroidHostSecrets
import AndroidHostContacts
import AndroidHostCalendars
import AndroidHostText
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
        AndroidHostModelStore.self,
        AndroidHostDocuments.self,
        AndroidHostNotifications.self,
        AndroidMedia.self,
        AndroidHostClipboard.self,
        AndroidHostSecrets.self,
        AndroidHostContacts.self,
        AndroidHostCalendars.self,
        AndroidHostText.self,
        AndroidHostAuthentication.self,
        AndroidHostBackgroundTasks.self,
    ]
}
