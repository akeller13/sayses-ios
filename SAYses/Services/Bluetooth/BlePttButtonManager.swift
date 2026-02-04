import Foundation
import CoreBluetooth

class BlePttButtonManager: NSObject, ObservableObject {
    // MARK: - Published properties for UI
    @Published var connectedDeviceName: String?
    @Published var isScanning: Bool = false

    // MARK: - Callbacks
    var onPttPressed: (() -> Void)?
    var onPttReleased: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    // MARK: - CoreBluetooth
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var reconnectPeripheral: CBPeripheral?

    // MARK: - Device name patterns
    private let deviceNamePatterns = ["Blu-PTT", "PTT", "BluePTT"]

    // MARK: - GATT descriptor for Client Characteristic Configuration
    private let cccdUUID = CBUUID(string: "2902")

    // MARK: - Double-click detection
    private let doubleClickThreshold: TimeInterval = 0.4
    private var lastPressTime: Date = .distantPast

    // MARK: - State
    private var isButtonPressed = false
    private var scanTimeoutTimer: Timer?
    private var reconnectTimer: Timer?
    private var initialized = false

    // MARK: - Public API

    func initialize() {
        guard !initialized else { return }
        initialized = true
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.sayses.ble-ptt",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        NSLog("[BlePttButtonManager] Initialized")
    }

    func startScan() {
        guard let centralManager = centralManager,
              centralManager.state == .poweredOn else {
            NSLog("[BlePttButtonManager] Cannot scan - Bluetooth not powered on")
            return
        }

        guard !isScanning else {
            NSLog("[BlePttButtonManager] Already scanning")
            return
        }

        NSLog("[BlePttButtonManager] Starting scan for PTT devices...")
        isScanning = true

        // Scan for all peripherals (BLE PTT devices don't advertise specific service UUIDs)
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // Timeout after 10 seconds, then retry
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isScanning && self.connectedPeripheral == nil {
                NSLog("[BlePttButtonManager] Scan timeout - restarting scan")
                self.centralManager.stopScan()
                self.isScanning = false
                // Restart scan after a brief pause
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startScan()
                }
            }
        }
    }

    func release() {
        NSLog("[BlePttButtonManager] Releasing resources")
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        reconnectPeripheral = nil
        connectedDeviceName = nil
        isScanning = false
    }

    // MARK: - Private helpers

    private func matchesDeviceName(_ name: String?) -> Bool {
        guard let name = name else { return false }
        let lowered = name.lowercased()
        return deviceNamePatterns.contains { lowered.contains($0.lowercased()) }
    }

    private func detectButtonPress(value: Data) {
        guard !value.isEmpty else { return }

        let firstByte = value[0]
        NSLog("[BlePttButtonManager] Characteristic value: \(value.map { String(format: "%02X", $0) }.joined(separator: " "))")

        if firstByte != 0x00 && !isButtonPressed {
            // Button pressed
            isButtonPressed = true
            NSLog("[BlePttButtonManager] Button PRESSED")

            // Double-click detection
            let now = Date()
            if now.timeIntervalSince(lastPressTime) < doubleClickThreshold {
                NSLog("[BlePttButtonManager] Double-click detected")
                onDoubleClick?()
                lastPressTime = .distantPast
                return
            }
            lastPressTime = now

            onPttPressed?()
        } else if firstByte == 0x00 && isButtonPressed {
            // Button released
            isButtonPressed = false
            NSLog("[BlePttButtonManager] Button RELEASED")
            onPttReleased?()
        }
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if let peripheral = self.reconnectPeripheral {
                NSLog("[BlePttButtonManager] Attempting reconnect to \(peripheral.name ?? "unknown")...")
                self.centralManager.connect(peripheral, options: nil)
            } else {
                NSLog("[BlePttButtonManager] No peripheral to reconnect - starting scan")
                self.startScan()
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BlePttButtonManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("[BlePttButtonManager] Bluetooth state: \(central.state.rawValue)")

        switch central.state {
        case .poweredOn:
            if let peripheral = connectedPeripheral {
                // Restored peripheral - re-discover services to re-subscribe to notifications
                NSLog("[BlePttButtonManager] Re-discovering services for restored peripheral: \(peripheral.name ?? "unknown")")
                peripheral.discoverServices(nil)
            } else {
                startScan()
            }
        case .poweredOff:
            DispatchQueue.main.async {
                self.connectedDeviceName = nil
                self.isScanning = false
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Restore connected peripherals after app relaunch
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            NSLog("[BlePttButtonManager] Restoring peripheral: \(peripheral.name ?? "unknown")")
            peripheral.delegate = self
            connectedPeripheral = peripheral
            reconnectPeripheral = peripheral
            DispatchQueue.main.async {
                self.connectedDeviceName = peripheral.name
            }
            // Don't discover services here - wait for centralManagerDidUpdateState(.poweredOn)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard matchesDeviceName(name) else { return }

        NSLog("[BlePttButtonManager] Found PTT device: \(name ?? "unknown") (RSSI: \(RSSI))")

        // Stop scanning
        central.stopScan()
        scanTimeoutTimer?.invalidate()
        isScanning = false

        // Connect
        connectedPeripheral = peripheral
        reconnectPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("[BlePttButtonManager] Connected to \(peripheral.name ?? "unknown")")

        DispatchQueue.main.async {
            self.connectedDeviceName = peripheral.name
        }

        // Discover all services
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("[BlePttButtonManager] Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        DispatchQueue.main.async {
            self.connectedDeviceName = nil
        }
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        NSLog("[BlePttButtonManager] Disconnected from \(peripheral.name ?? "unknown"): \(error?.localizedDescription ?? "no error")")

        DispatchQueue.main.async {
            self.connectedDeviceName = nil
        }

        // If button was pressed during disconnect, send release
        if isButtonPressed {
            isButtonPressed = false
            onPttReleased?()
        }

        // Auto-reconnect
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate
extension BlePttButtonManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            NSLog("[BlePttButtonManager] Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }
        NSLog("[BlePttButtonManager] Discovered \(services.count) services")

        for service in services {
            NSLog("[BlePttButtonManager] Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            NSLog("[BlePttButtonManager] Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            NSLog("[BlePttButtonManager] Characteristic: \(characteristic.uuid), properties: \(characteristic.properties)")

            // Subscribe to NOTIFY or INDICATE characteristics
            if characteristic.properties.contains(.notify) {
                NSLog("[BlePttButtonManager] Subscribing to NOTIFY: \(characteristic.uuid)")
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.properties.contains(.indicate) {
                NSLog("[BlePttButtonManager] Subscribing to INDICATE: \(characteristic.uuid)")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            NSLog("[BlePttButtonManager] Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        NSLog("[BlePttButtonManager] Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            NSLog("[BlePttButtonManager] Value update error: \(error.localizedDescription)")
            return
        }

        guard let value = characteristic.value else { return }
        detectButtonPress(value: value)
    }
}
