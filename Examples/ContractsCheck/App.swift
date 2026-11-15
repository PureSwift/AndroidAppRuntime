// The contracts check's manifest (DynamicRuntime.md §7.1): the capabilities
// its checks use, with background location, so the check can run the
// host's foreground service. Scripts/contracts-check.sh builds it with:
//
//     guest.py bundle --package Examples/ContractsCheck --manifest Examples/ContractsCheck/App.swift
import AppManifest

let app = App(
    id: "org.pureswift.ContractsCheck",
    name: "ContractsCheck",
    version: "1.0", build: 1,
    product: "ContractsCheck",
    capabilities: [
        .location(.always, usage: "The check reads the emulator's location, also in the background."),
        .network,
        .bluetooth(usage: "The check scans for Bluetooth devices."),
        .motion(usage: "The check counts steps."),
        .nfc(usage: "The check starts an NFC session."),
    ],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
