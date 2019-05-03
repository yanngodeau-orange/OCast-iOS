//
// TestDeviceDiscovery.swift
//
// Copyright 2019 Orange
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
@testable import OCast

/// Converts a DeviceDiscoveryDelegate delegate to closure style...
class TestDeviceDiscoveryDelegate: DeviceDiscoveryDelegate {
    
    var devicesAdded: (_: [Device]) -> Void
    var devicesRemoved: (_: [Device]) -> Void
    var discoveryStopped: (_: Error?) -> Void
    
    init() {
        self.devicesAdded = { _ in }
        self.devicesRemoved = { _ in }
        self.discoveryStopped = { _ in }
    }
    
    func deviceDiscovery(_ deviceDiscovery: DeviceDiscovery, didAddDevices devices: [Device]) {
        devicesAdded(devices)
    }
    
    func deviceDiscovery(_ deviceDiscovery: DeviceDiscovery, didRemoveDevices devices: [Device]) {
        devicesRemoved(devices)
    }
    
    func deviceDiscoveryDidStop(_ deviceDiscovery: DeviceDiscovery, withError error: Error?) {
        discoveryStopped(error)
    }
}

class TestDeviceDiscovery: XCTestCase {

    private var mockDevice: Device!
    private var mockUPNPService: MockUPNPService!
    private var mockUDPSocket: MockUDPSocket!
    private var deviceDiscovery: DeviceDiscovery!
    private var testDeviceDiscoveryDelegate: TestDeviceDiscoveryDelegate?
    
    override func setUp() {
        testDeviceDiscoveryDelegate = TestDeviceDiscoveryDelegate()
        let location = "http://127.0.0.1/dd.xml"
        let searchTarget = "urn:foo-org:service:foo:1"
        let server = "Foo/1.0 UPnP/2.0 CléTV/2.0"
        let USN = "uuid:abcd-efgh-ijkl"
        // Multiline adds the LF to obtain CRLF sequence
        let mSearchResponseString = """
        HTTP/1.1 200 OK\r
        CACHE-CONTROL: max-age = 0\r
        EXT:\r
        LOCATION: \(location)\r
        SERVER: \(server)\r
        ST: \(searchTarget)\r
        USN: \(USN)\r
        BOOTID.UPNP.ORG: 1\r
        
        """
        mockDevice = Device(baseURL: URL(string: "http://foo")!,
                            ipAddress: "127.0.0.1",
                            servicePort: 8080,
                            deviceID: "DeviceID",
                            friendlyName: "Name",
                            manufacturer: "Manufacturer",
                            modelName: "Model")
        mockUDPSocket = MockUDPSocket(responsePayload: mSearchResponseString)
        mockUPNPService = MockUPNPService(device: mockDevice)
        deviceDiscovery = DeviceDiscovery(["urn:foo-org:service:foo:1"],
                                          udpSocket: mockUDPSocket,
                                          upnpService: mockUPNPService)
        deviceDiscovery.delegate = testDeviceDiscoveryDelegate
    }

    override func tearDown() {
    }

    func testDeviceDiscoveryResume() {
        deviceDiscovery = DeviceDiscovery([""], udpSocket: MockUDPSocket(responsePayload: ""))
        XCTAssertTrue(deviceDiscovery.resume())
        XCTAssertFalse(deviceDiscovery.resume())
    }
    
    func testDeviceDiscoveryNewDeviceFound() {
        let expectation = assertDevicesAdded()
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testDeviceDiscoveryDeviceLost() {
        let devicesAddedExpectation = assertDevicesAdded()
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [devicesAddedExpectation], timeout: 5.0)
        
        deviceDiscovery.interval = 5
        mockUDPSocket.responseDelay = 100.0
        
        let devicesRemovedExpectation = assertDevicesRemoved()
        
        wait(for: [devicesRemovedExpectation], timeout: 10.0)
        XCTAssertTrue(deviceDiscovery.devices.isEmpty)
    }
    
    func testDeviceDiscoveryStop() {
        let devicesAddedExpectation = assertDevicesAdded()
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [devicesAddedExpectation], timeout: 5.0)
        
        let discoveryStoppedExpectation = assertDiscoveryStopped()
        let devicesRemovedExpectation = assertDevicesRemoved()
        XCTAssertTrue(deviceDiscovery.stop())
        XCTAssertFalse(deviceDiscovery.stop())
        
        wait(for: [devicesRemovedExpectation, discoveryStoppedExpectation], timeout: 5.0, enforceOrder: true)
        XCTAssertTrue(deviceDiscovery.devices.isEmpty)
    }
    
    func testDeviceDiscoveryResumeStopResume() {
        let firstDevicesAddedExpectation = assertDevicesAdded()
        // If the discovery is stopped immediatly after resuming it, no devices should be added
        firstDevicesAddedExpectation.isInverted = true
        let secondDevicesAddedExpectation = assertDevicesAdded()
        let discoveryStoppedExpectation = assertDiscoveryStopped()
        
        XCTAssertTrue(deviceDiscovery.resume())
        XCTAssertTrue(deviceDiscovery.stop())
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [firstDevicesAddedExpectation, discoveryStoppedExpectation, secondDevicesAddedExpectation], timeout: 5.0, enforceOrder: true)
    }
    
    func testDeviceDiscoveryPause() {
        let devicesAddedExpectation = assertDevicesAdded()
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [devicesAddedExpectation], timeout: 5.0)
        
        XCTAssertTrue(deviceDiscovery.pause())
        XCTAssertEqual(1, self.deviceDiscovery.devices.count)
        XCTAssertFalse(deviceDiscovery.pause())
    }
    
    func testDeviceDiscoveryResumePauseResume() {
        let devicesAddedExpectation = assertDevicesAdded()
        
        XCTAssertTrue(deviceDiscovery.resume())
        XCTAssertTrue(deviceDiscovery.pause())
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [devicesAddedExpectation], timeout: 5.0)
    }
    
    func testDeviceDiscoveryPauseStop() {
        let devicesAddedExpectation = assertDevicesAdded()
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [devicesAddedExpectation], timeout: 5.0)
        
        XCTAssertTrue(deviceDiscovery.pause())
        XCTAssertEqual(1, self.deviceDiscovery.devices.count)
        
        let discoveryStoppedExpectation = assertDiscoveryStopped()
        XCTAssertTrue(deviceDiscovery.stop())
        
        wait(for: [discoveryStoppedExpectation], timeout: 5.0)
    }
    
    func testDeviceDiscoveryStopPause() {
        let devicesAddedExpectation = assertDevicesAdded()
        let discoveryStoppedExpectation = assertDiscoveryStopped()
        XCTAssertTrue(deviceDiscovery.resume())
        
        wait(for: [devicesAddedExpectation], timeout: 5.0)
        
        XCTAssertTrue(deviceDiscovery.stop())
        
        wait(for: [discoveryStoppedExpectation], timeout: 5.0)
        
        XCTAssertFalse(deviceDiscovery.pause())
    }
    
    private func assertDevicesAdded() -> XCTestExpectation {
        let expectation = self.expectation(description: "devicesAdded")
        testDeviceDiscoveryDelegate?.devicesAdded = { devices in
            expectation.fulfill()
            XCTAssertEqual(1, devices.count)
            XCTAssertEqual(1, self.deviceDiscovery.devices.count)
            XCTAssertEqual(self.mockDevice.deviceID, devices[0].deviceID)
        }
        
        return expectation
    }
    
    private func assertDevicesRemoved() -> XCTestExpectation {
        let expectation = self.expectation(description: "devicesRemoved")
        testDeviceDiscoveryDelegate?.devicesRemoved = { devices in
            expectation.fulfill()
        }
        
        return expectation
    }
    
    private func assertDiscoveryStopped() -> XCTestExpectation {
        let expectation = self.expectation(description: "discoveryStopped")
        testDeviceDiscoveryDelegate?.discoveryStopped = { error in
            expectation.fulfill()
            XCTAssertNil(error)
            XCTAssertTrue(self.deviceDiscovery.devices.isEmpty)
        }
        
        return expectation
    }
}
