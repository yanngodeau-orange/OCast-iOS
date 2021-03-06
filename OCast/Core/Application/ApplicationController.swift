//
// ApplicationController.swift
//
// Copyright 2017 Orange
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

import Foundation

/**
 Provides means to control the web application.
 
 The ApplicationController gives you access to the `MediaController` object which provides your application with basic cast control functions.
 
 It also gives you access to custom messaging thru the `maangeStream()` function.

 A reference to the ApplicationController can be obtained using the `DeviceManager` class via the `getApplicationController()` function.

 ```
 deviceMgr.getApplicationController (
    for: applicationName,

    onSuccess: {applicationController in
        self.applicationController = applicationController
    },

    onError: {error in
        print ("-> ERROR for Application controller = \(String(describing: error))")
    }
 )

 ```
 */
@objcMembers

public class ApplicationController: NSObject, DataStream, HttpProtocol {

    /// device controlled
    var device: Device
    // driver for device
    var driver: Driver?
    // url of device
    var target: String
    // application's state
    var currentState: State = .stopped
    // application's information
    var applicationData: ApplicationDescription
    // browser
    var browser: Browser?
    
    enum State: String {
        case running
        case stopped
    }
    
    /// The MediaController to manage media
    public lazy var mediaController: MediaController = {
        let mediaController = MediaController()
        manage(stream: mediaController)
        
        return mediaController
    }()
    
    // Timer
    private var semaphore: DispatchSemaphore?
    private var isConnectedEvent = false
    
    // MARK: - Public interface
    /// Create a controller for the application of stick
    ///
    /// - Parameters:
    ///   - device: device to control
    ///   - applicationData: application's information
    ///   - target: target url of device
    ///   - driver: driver for device
    init(for device: Device, with applicationData: ApplicationDescription, target: String, driver: Driver?) {
        self.device = device
        self.applicationData = applicationData
        self.target = target
        self.driver = driver
        
        super.init()
        
        semaphore = DispatchSemaphore(value: 0)
    }

    /// Starts the web application on the device and opens a dedicated connection at driver level to communicate with the stick.
    ///
    /// - Parameters:
    ///   - onSuccess: the closure to be called in case of success.
    ///   - onError: the closure to be called in case of error.
    public func start(onSuccess: @escaping () -> Void, onError: @escaping (_ error: NSError?) -> Void) {
        manage(stream: self)
        
        // Closures executed on main thread
        let successOnMainThread = { () in
            DispatchQueue.main.async {
                onSuccess()
            }
        }
        let errorOnMainThread = { (error:NSError?) in
            DispatchQueue.main.async {
                onError(error)
            }
        }
        
        if driver?.state(for: .application) != .connected {
            driver?.connect(for: .application, with: applicationData,
                            onSuccess: { [weak self] in
                                guard let `self` = self else { return }
                                
                                self.applicationStatus(onSuccess: { [weak self] in
                                    guard let `self` = self else { return }
                                    
                                    if self.currentState == .running {
                                        successOnMainThread()
                                    } else {
                                        self.startApplication(onSuccess: successOnMainThread, onError: errorOnMainThread)
                                    }
                                }, onError: errorOnMainThread)
            }
                , onError: errorOnMainThread)
        } else {
            self.applicationStatus(onSuccess: { [weak self] in
                guard let `self` = self else { return }

                if self.currentState == .running {
                    successOnMainThread()
                } else {
                    self.startApplication(onSuccess: successOnMainThread, onError: errorOnMainThread)
                }
            }, onError: errorOnMainThread)
        }
    }

    ///  Stops the web application on the device. Releases the dedicated web application connection at driver level.
    ///
    /// - Parameters:
    ///   - onSuccess: the closure to be called in case of success.
    ///   - onError: the closure to be called in case of error.
    public func stop(onSuccess: @escaping () -> Void, onError: @escaping (_ error: NSError?) -> Void) {
        
        // Closures executed on main thread
        let successOnMainThread = { () in
            DispatchQueue.main.async {
                onSuccess()
            }
        }
        let errorOnMainThread = { (error:NSError?) in
            DispatchQueue.main.async {
                onError(error)
            }
        }
        
        applicationStatus(onSuccess: { [weak self] in
            guard let `self` = self else { return }

            if self.currentState == .running {
                self.stopApplication(onSuccess: { [weak self] in
                    guard let `self` = self else { return }

                    self.driver?.disconnect(for: .application, onSuccess: successOnMainThread, onError: errorOnMainThread)
                }, onError: errorOnMainThread)
            } else {
                successOnMainThread()
            }
        }, onError: errorOnMainThread)
    }


    /// Used to get control over a user's specific stream.
    /// You need this when dealing with custom streams. See `DataStream` for details on custom messaging.
    /// Create a CustomStream class implementing the DataStream protocol
    /// customStream = CustomStream()
    /// Register it so the application manager knows how to handle it.
    /// applicationController.manageStream(for: customStream)
    ///
    /// - Parameter stream: custom stream to be managed
    public func manage(stream: DataStream) {
        if browser == nil {
            browser = Browser()
            browser?.delegate = driver
        }
        if let browser = browser {
            stream.dataSender = DefaultDataSender(browser: browser, serviceId: stream.serviceId)
            browser.register(stream: stream)
        } else {
            OCastLog.error("Unable to manage stream (\(stream.serviceId) because browser is nil")
        }
    }
    
    /// Used to release control over a user's specific stream.
    ///
    /// - Parameter stream: custom stream to be unmanaged
    public func unmanage(stream: DataStream) {
        if let browser = browser {
            stream.dataSender = nil
            browser.unregister(stream: stream)
        } else {
            OCastLog.error("Unable to unmanage stream (\(stream.serviceId) because browser is nil")
        }
    }

    // MARK: private methods
    private func startApplication(onSuccess: @escaping () -> Void, onError: @escaping (_ error: NSError?) -> Void) {
        initiateHttpRequest(with: .post, to: target, onSuccess: { [weak self] (response, _) in
            guard let `self` = self else { return }

            if response.statusCode == 201 {
                self.applicationStatus(onSuccess: { [weak self] in
                    guard let `self` = self else { return }
                    
                    self.isConnectedEvent = false
                    let _ = self.semaphore?.wait(timeout: .now() + 60)
                    if self.isConnectedEvent {
                        onSuccess()
                    } else {
                        let error = NSError(domain: "ApplicationController", code: 0, userInfo: ["Error": "No message received from WS"])
                        onError(error)
                    }
                }, onError: { (error) in
                    onError(error)
                })
            } else {
                let error = NSError(domain: "ApplicationController", code: 0, userInfo: ["Error": "Application cannot be run."])
                onError(error)
            }
        }) { (error) in
            onError(error)
        }
    }
    
    private func stopApplication(onSuccess: @escaping () -> Void, onError: @escaping (_ error: NSError?) -> Void) {
       
        var stopLink:String!
        if  let runLink = applicationData.runLink,
            let url = URL(string: runLink),
            let _ = url.host {
            stopLink = runLink
        } else if let runLink = URL(string: target)?.appendingPathComponent(applicationData.runLink ?? "run").absoluteString {
            stopLink = runLink
        } else {
            let error = NSError(domain: "ApplicationController", code: 0, userInfo: ["Error": "Bad run link"])
            onError(error)
            return
        }

        initiateHttpRequest(with: .delete, to: stopLink, onSuccess: { [weak self] (_, _) in
            guard let `self` = self else { return }
            
            self.applicationStatus(onSuccess: {
                if self.currentState == .stopped {
                    onSuccess()
                } else {
                    let error = NSError(domain: "ApplicationController", code: 0, userInfo: ["Error": "Application is not stopped."])
                    onError(error)
                }
            }, onError: { (error) in
                onError(error)
            })
        }) { (error) in
            onError(error)
        }
    }
    
    private func applicationStatus(onSuccess: @escaping () -> Void, onError: @escaping (_ error: NSError?) -> Void) {
        initiateHttpRequest(with: .get, to: target, onSuccess: { (_, data) in
            guard let data = data else {
                OCastLog.error("ApplicationMgr: No content to parse.")
                let error = NSError(domain: "ApplicationController", code: 0, userInfo: ["Error": "No content for status dial page"])
                onError(error)
                return
            }
            let xmlParser = XMLHelper()
            xmlParser.completionHandler = { [weak self] (error, result, attributes) -> Void in
                guard let `self` = self else { return }
                
                if error == nil {
                    guard let state = result?["state"],
                        let _ = result?["name"],
                        let newState = State(rawValue: state) else {
                        let newError = NSError(domain: "ApplicationController", code: 0, userInfo: ["Error": "Missing parameters state/name"])
                        onError(newError)
                        return
                    }
                    self.currentState = newState
                    onSuccess()
                } else {
                    let newError = NSError(domain: "ApplicationController", code: 0, userInfo: ["Error": "Parsing error for \(self.target)\n Error: \(error?.localizedDescription ?? "")."])
                    onError(newError)
                }
            }
            xmlParser.parseDocument(data: data)
        }) { (error) in
            onError(error)
        }
    }
    
    // MARK: - DataStream methods
    static let applicationServiceId = "org.ocast.webapp"
    /// :nodoc:
    public let serviceId = ApplicationController.applicationServiceId
    /// :nodoc:
    public var dataSender: DataSender?
    /// :nodoc:
    public func onMessage(data: [String: Any]) {
        let name = data["name"] as? String
        if name == "connectedStatus" {
            let params = data["params"] as? [String: String]
            if params?["status"] == "connected" {
                isConnectedEvent = true
                semaphore?.signal()
            }
        }
    }
}
