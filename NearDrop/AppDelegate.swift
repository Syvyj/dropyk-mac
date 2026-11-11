//
//  AppDelegate.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Cocoa
import CryptoKit
import Security
import UserNotifications
import ServiceManagement
import NearbyShare

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MainAppDelegate{
	private var statusItem:NSStatusItem?
	private var activeIncomingTransfers:[String:TransferInfo]=[:]
	private var updateItem:NSMenuItem?
	private var update:Updates.Release?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
		let menu=NSMenu()
		// Shown at the top once a newer release is found.
		let updateItem=menu.addItem(withTitle: "", action: #selector(installUpdate), keyEquivalent: "")
		updateItem.isHidden=true
		self.updateItem=updateItem
		menu.addItem(withTitle: NSLocalizedString("VisibleToEveryone", value: "Visible to everyone", comment: ""), action: nil, keyEquivalent: "")
		menu.addItem(withTitle: String(format: NSLocalizedString("DeviceName", value: "Device name: %@", comment: ""), arguments: [Host.current().localizedName!]), action: nil, keyEquivalent: "")
		let autoAcceptItem=menu.addItem(withTitle: NSLocalizedString("AutoAccept", value: "Accept transfers automatically", comment: ""), action: #selector(toggleAutoAccept(_:)), keyEquivalent: "")
		autoAcceptItem.state=UserDefaults.standard.bool(forKey: "autoAccept") ? .on : .off
		if #available(macOS 13.0, *){
			let loginItem=menu.addItem(withTitle: NSLocalizedString("LaunchAtLogin", value: "Open at Login", comment: ""), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
			loginItem.state=SMAppService.mainApp.status == .enabled ? .on : .off
		}
		menu.addItem(withTitle: NSLocalizedString("CheckForUpdates", value: "Check for Updates…", comment: ""), action: #selector(checkForUpdatesNow), keyEquivalent: "")
		menu.addItem(NSMenuItem.separator())
		menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit Dropyk", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
		statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem?.button?.image=NSImage(named: "MenuBarIcon")
		statusItem?.menu=menu
		statusItem?.behavior = .removalAllowed
		
		let nc=UNUserNotificationCenter.current()
		nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
			if !granted{
				DispatchQueue.main.async {
					self.showNotificationsDeniedAlert()
				}
			}
		}
		nc.delegate=self
		let incomingTransfersCategory=UNNotificationCategory(identifier: "INCOMING_TRANSFERS", actions: [
			UNNotificationAction(identifier: "ACCEPT", title: NSLocalizedString("Accept", comment: ""), options: UNNotificationActionOptions.authenticationRequired),
			UNNotificationAction(identifier: "DECLINE", title: NSLocalizedString("Decline", comment: ""))
		], intentIdentifiers: [])
		let errorsCategory=UNNotificationCategory(identifier: "ERRORS", actions: [], intentIdentifiers: [])
		nc.setNotificationCategories([incomingTransfersCategory, errorsCategory])
		NearbyConnectionManager.shared.mainAppDelegate=self
		NearbyConnectionManager.shared.becomeVisible()
		startUpdateChecks()
	}
	
	// MARK: Updates
	
	/// On launch, then once a day: a newer release puts "Update to Dropyk X…" at the top of the menu.
	private func startUpdateChecks(){
		Task{
			var launch=true
			while true{
				let last=UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
				if launch || Date().timeIntervalSince(last)>86_400, let release=try? await Updates.latest(){
					UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
					await MainActor.run{ self.show(release) }
				}
				launch=false
				try? await Task.sleep(nanoseconds: 3_600_000_000_000)
			}
		}
	}
	
	private func show(_ release:Updates.Release){
		let newer=Updates.isNewer(release.version, than: Updates.current)
		update=newer ? release : nil
		updateItem?.title=String(format: NSLocalizedString("UpdateTo", value: "Update to Dropyk %@…", comment: ""), release.version)
		updateItem?.isHidden = !newer
	}
	
	/// "Check for Updates…": the answer right away.
	@objc func checkForUpdatesNow(){
		Task{
			guard let release=try? await Updates.latest() else {
				// Asked for by the person: say it failed, don't just open a browser.
				await MainActor.run{
					let alert=NSAlert()
					alert.messageText=NSLocalizedString("CheckFailed", value: "Couldn’t check for updates", comment: "")
					alert.informativeText=NSLocalizedString("CheckFailedInfo", value: "GitHub didn’t answer. Check the internet connection, or see the releases page.", comment: "")
					alert.addButton(withTitle: NSLocalizedString("Download", value: "Download", comment: ""))
					alert.addButton(withTitle: NSLocalizedString("Cancel", value: "Cancel", comment: ""))
					NSApp.activate(ignoringOtherApps: true)
					if alert.runModal() == .alertFirstButtonReturn{ NSWorkspace.shared.open(Updates.releases) }
				}
				return
			}
			await MainActor.run{
				self.show(release)
				if self.update != nil{
					self.installUpdate()
				}else{
					let alert=NSAlert()
					alert.messageText=NSLocalizedString("UpToDate", value: "Dropyk is up to date", comment: "")
					alert.informativeText=String(format: NSLocalizedString("UpToDateInfo", value: "Version %@ is the newest.", comment: ""), Updates.current)
					NSApp.activate(ignoringOtherApps: true)
					alert.runModal()
				}
			}
		}
	}
	
	/// Asks, then downloads, checks and restarts into the new version.
	@objc func installUpdate(){
		guard let release=update else { return }
		let ask=NSAlert()
		ask.messageText=String(format: NSLocalizedString("UpdateAsk", value: "Update to Dropyk %@?", comment: ""), release.version)
		ask.informativeText=NSLocalizedString("UpdateAskInfo", value: "Dropyk downloads the new version, checks it and restarts.", comment: "")
		ask.addButton(withTitle: NSLocalizedString("Update", value: "Update", comment: ""))
		ask.addButton(withTitle: NSLocalizedString("Cancel", value: "Cancel", comment: ""))
		NSApp.activate(ignoringOtherApps: true)
		guard ask.runModal() == .alertFirstButtonReturn else { return }
		updateItem?.isEnabled=false
		Task{
			do{
				let staged=try await Updates.prepare(release)
				await MainActor.run{ Updates.swapAndRelaunch(staged) }
			}catch{
				await MainActor.run{
					self.updateItem?.isEnabled=true
					let alert=NSAlert()
					alert.messageText=NSLocalizedString("UpdateFailed", value: "Couldn’t update Dropyk", comment: "")
					alert.informativeText=error.localizedDescription
					alert.addButton(withTitle: NSLocalizedString("Download", value: "Download", comment: ""))
					alert.addButton(withTitle: NSLocalizedString("Cancel", value: "Cancel", comment: ""))
					if alert.runModal() == .alertFirstButtonReturn{ NSWorkspace.shared.open(Updates.releases) }
				}
			}
		}
	}
	
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		statusItem?.isVisible=true
		return true
	}

    func applicationWillTerminate(_ aNotification: Notification) {
		UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
	
	func showNotificationsDeniedAlert(){
		let alert=NSAlert()
		alert.alertStyle = .critical
		alert.messageText=NSLocalizedString("NotificationsDenied.Title", value: "Notification Permission Required", comment: "")
		alert.informativeText=NSLocalizedString("NotificationsDenied.Message", value: "Dropyk needs to be able to display notifications for incoming file transfers. Please allow notifications in System Settings.", comment: "")
		alert.addButton(withTitle: NSLocalizedString("NotificationsDenied.OpenSettings", value: "Open settings", comment: ""))
		alert.addButton(withTitle: NSLocalizedString("Quit", value: "Quit Dropyk", comment: ""))
		let result=alert.runModal()
		if result==NSApplication.ModalResponse.alertFirstButtonReturn{
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
		}else if result==NSApplication.ModalResponse.alertSecondButtonReturn{
			NSApplication.shared.terminate(nil)
		}
	}
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		let userInfo=response.notification.request.content.userInfo
		// "Received": show the files in Finder.
		if let paths=userInfo["reveal"] as? [String]{
			NSWorkspace.shared.activateFileViewerSelecting(paths.map{ URL(fileURLWithPath: $0) })
			completionHandler()
			return
		}
		// Error notifications carry no transfer: clicking one used to crash the app.
		guard let transferID=userInfo["transferID"] as? String else {
			completionHandler()
			return
		}
		NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: response.actionIdentifier=="ACCEPT")
		if response.actionIdentifier != "ACCEPT"{
			activeIncomingTransfers.removeValue(forKey: transferID)
		}
		completionHandler()
	}
	
	@objc func toggleAutoAccept(_ sender:NSMenuItem){
		let enabled = sender.state != .on
		UserDefaults.standard.set(enabled, forKey: "autoAccept")
		sender.state=enabled ? .on : .off
	}

	/// "Open at Login": the system's own login item, the same one System Settings → Login Items lists.
	@available(macOS 13.0, *)
	@objc func toggleLaunchAtLogin(_ sender:NSMenuItem){
		let service=SMAppService.mainApp
		do{
			if service.status == .enabled{
				try service.unregister()
			}else{
				try service.register()
				// macOS may want the person to switch it on there first.
				if service.status == .requiresApproval{ SMAppService.openSystemSettingsLoginItems() }
			}
		}catch{
			NSApp.activate(ignoringOtherApps: true)
			NSAlert(error: error).runModal()
		}
		sender.state=service.status == .enabled ? .on : .off
	}

	/// Something arrived — with automatic accepting, the only sign of it. Clicking shows the files in Finder.
	private func notifyReceived(_ files:[URL], from device:RemoteDeviceInfo){
		let content=UNMutableNotificationContent()
		content.title=String(format: NSLocalizedString("ReceivedTitle", value: "Received from %@", comment: ""), device.name)
		content.subtitle=NSLocalizedString("ShowInFinder", value: "Click to show in Finder", comment: "")
		content.body=files.count==1 ? files[0].lastPathComponent : String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), files.count)
		content.userInfo=["reveal": files.map(\.path)]
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "received_"+UUID().uuidString, content: content, trigger: nil))
	}

	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
		// ponytail: accepts from anyone on the LAN; add a per-device allowlist if that ever matters
		if UserDefaults.standard.bool(forKey: "autoAccept"){
			self.activeIncomingTransfers[transfer.id]=TransferInfo(device: device, transfer: transfer)
			NearbyConnectionManager.shared.submitUserConsent(transferID: transfer.id, accept: true)
			return
		}
		let fileStr:String
		if let textTitle=transfer.textDescription{
			fileStr=textTitle
		}else if transfer.files.count==1{
			fileStr=transfer.files[0].name
		}else{
			fileStr=String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), transfer.files.count)
		}
		let notificationContent=UNMutableNotificationContent()
		notificationContent.title="Dropyk"
		notificationContent.subtitle=String(format:NSLocalizedString("PinCode", value: "PIN: %@", comment: ""), arguments: [transfer.pinCode!])
		notificationContent.body=String(format: NSLocalizedString("DeviceSendingFiles", value: "%1$@ is sending you %2$@", comment: ""), arguments: [device.name, fileStr])
		notificationContent.sound = .default
		notificationContent.categoryIdentifier="INCOMING_TRANSFERS"
		notificationContent.userInfo=["transferID": transfer.id]
		if #available(macOS 11.0, *){
			NDNotificationCenterHackery.removeDefaultAction(notificationContent)
		}
		let notificationReq=UNNotificationRequest(identifier: "transfer_"+transfer.id, content: notificationContent, trigger: nil)
		UNUserNotificationCenter.current().add(notificationReq)
		self.activeIncomingTransfers[transfer.id]=TransferInfo(device: device, transfer: transfer)
	}
	
	func incomingTransfer(id: String, didFinishWith error: Error?, saved: [URL]) {
		guard let transfer=self.activeIncomingTransfers[id] else {return}
		if error==nil && !saved.isEmpty{
			notifyReceived(saved, from: transfer.device)
		}
		if let error=error{
			let notificationContent=UNMutableNotificationContent()
			notificationContent.title=String(format: NSLocalizedString("TransferError", value: "Failed to receive files from %@", comment: ""), arguments: [transfer.device.name])
			if let ne=(error as? NearbyError){
				switch ne{
				case .inputOutput:
					notificationContent.body="I/O Error";
				case .protocolError(_):
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .requiredFieldMissing:
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .ukey2:
					notificationContent.body=NSLocalizedString("Error.Crypto", value: "Encryption error", comment: "")
				case .canceled(reason: _):
					break; // can't happen for incoming transfers
				}
			}else{
				notificationContent.body=error.localizedDescription
			}
			notificationContent.categoryIdentifier="ERRORS"
			UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transferError_"+id, content: notificationContent, trigger: nil))
		}
		UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_"+id])
		self.activeIncomingTransfers.removeValue(forKey: id)
	}
}

struct TransferInfo{
	let device:RemoteDeviceInfo
	let transfer:TransferMetadata
}

/// The newest Dropyk release on GitHub, and installing it from inside the app — the same
/// scheme as Shotleaf. Nothing about the user goes with the request.
enum Updates{
	struct Release{
		let version:String
		let download:URL
		/// The release's "Dropyk.dmg.sha256", needed to install it from inside the app.
		let checksum:URL?
	}
	
	static let api=URL(string: "https://api.github.com/repos/Syvyj/dropyk-mac/releases/latest")!
	static let releases=URL(string: "https://github.com/Syvyj/dropyk-mac/releases/latest")!
	
	static var current:String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
	
	/// "0.10.0" is newer than "0.9.1"; a leading "v" is ignored.
	static func isNewer(_ a:String, than b:String) -> Bool{
		let parts={ (s:String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map{ Int($0) ?? 0 } }
		let x=parts(a), y=parts(b)
		for i in 0..<max(x.count, y.count){
			let l = i<x.count ? x[i] : 0, r = i<y.count ? y[i] : 0
			if l != r { return l>r }
		}
		return false
	}
	
	static func latest() async throws -> Release{
		var request=URLRequest(url: api, timeoutInterval: 20)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		let (data, response)=try await URLSession.shared.data(for: request)
		guard (response as? HTTPURLResponse)?.statusCode==200 else { throw URLError(.badServerResponse) }
		struct Answer:Decodable{
			struct Asset:Decodable{ let name:String; let browser_download_url:URL }
			let tag_name:String
			let assets:[Asset]
		}
		let answer=try JSONDecoder().decode(Answer.self, from: data)
		let dmg=answer.assets.first{ $0.name.hasSuffix(".dmg") }?.browser_download_url ?? releases
		let sum=answer.assets.first{ $0.name.hasSuffix(".dmg.sha256") }?.browser_download_url
		return Release(version: answer.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v")), download: dmg, checksum: sum)
	}
	
	/// Why an update couldn't be installed; the user can still download it by hand.
	enum Failure:LocalizedError{
		case notWritable, checksum, signature, unpack
		
		var errorDescription:String?{
			switch self{
			case .notWritable: return NSLocalizedString("UpdateNotWritable", value: "Dropyk can’t replace itself in the folder it’s in.", comment: "")
			case .checksum: return NSLocalizedString("UpdateChecksum", value: "The download doesn’t match the release.", comment: "")
			case .signature: return NSLocalizedString("UpdateSignature", value: "The downloaded app isn’t signed like this one.", comment: "")
			case .unpack: return NSLocalizedString("UpdateUnpack", value: "The downloaded disk image couldn’t be opened.", comment: "")
			}
		}
	}
	
	/// "5e1c…  Dropyk.dmg" → "5e1c…" (a SHA-256 in hex), else nil.
	static func checksum(in file:String) -> String?{
		guard let first=file.split(whereSeparator: \.isWhitespace).first?.lowercased(),
			  first.count==64, first.allSatisfy(\.isHexDigit) else { return nil }
		return first
	}
	
	/// Downloads the release, checks it against its checksum and against this app's own
	/// signature (same identifier, same certificate), and puts the new copy next to this
	/// one. Downloaded by the app itself, it isn't marked as from the internet, so macOS
	/// doesn't ask again on its first launch.
	static func prepare(_ release:Release) async throws -> URL{
		let folder=Bundle.main.bundleURL.deletingLastPathComponent()
		guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notWritable }
		guard let sumURL=release.checksum else { throw Failure.checksum }
		let (sum, _)=try await URLSession.shared.data(from: sumURL)
		let (dmg, _)=try await URLSession.shared.download(from: release.download)
		defer{ try? FileManager.default.removeItem(at: dmg) }
		let digest=SHA256.hash(data: try Data(contentsOf: dmg)).map{ String(format: "%02x", $0) }.joined()
		guard checksum(in: String(decoding: sum, as: UTF8.self))==digest else { throw Failure.checksum }
		
		let mount=FileManager.default.temporaryDirectory.appendingPathComponent("dropyk-update-\(UUID().uuidString)")
		guard run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path) else { throw Failure.unpack }
		defer{ _=run("/usr/bin/hdiutil", "detach", mount.path, "-force") }
		let staged=folder.appendingPathComponent(".Dropyk-update.app")
		try? FileManager.default.removeItem(at: staged)
		guard run("/usr/bin/ditto", mount.appendingPathComponent("Dropyk.app").path, staged.path) else { throw Failure.unpack }
		guard signedLikeThisApp(staged) else {
			try? FileManager.default.removeItem(at: staged)
			throw Failure.signature
		}
		return staged
	}
	
	/// The new copy passes this app's designated requirement: its bundle identifier and
	/// the certificate it's signed with ("Dropyk Local Signing").
	static func signedLikeThisApp(_ app:URL) -> Bool{
		var me:SecCode?, mine:SecStaticCode?, requirement:SecRequirement?, other:SecStaticCode?
		guard SecCodeCopySelf([], &me)==errSecSuccess, let me,
			  SecCodeCopyStaticCode(me, [], &mine)==errSecSuccess, let mine,
			  SecCodeCopyDesignatedRequirement(mine, [], &requirement)==errSecSuccess, let requirement,
			  SecStaticCodeCreateWithPath(app as CFURL, [], &other)==errSecSuccess, let other
		else { return false }
		let flags=SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
		return SecStaticCodeCheckValidity(other, flags, requirement)==errSecSuccess
	}
	
	/// Once this app has quit: the new copy takes its place (the old one comes back if
	/// that fails) and starts. Same place and signature, so the permissions stay.
	static func swapAndRelaunch(_ staged:URL){
		let task=Process()
		task.executableURL=URL(fileURLWithPath: "/bin/sh")
		task.arguments=["-c", """
			while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
			rm -rf "$2"
			if mv "$0" "$2" && mv "$1" "$0"; then rm -rf "$2"; else [ -d "$0" ] || mv "$2" "$0"; fi
			open "$0"
			""", Bundle.main.bundlePath, staged.path, Bundle.main.bundlePath+".old"]
		try? task.run()
		NSApp.terminate(nil)
	}
	
	@discardableResult
	private static func run(_ tool:String, _ arguments:String...) -> Bool{
		let task=Process()
		task.executableURL=URL(fileURLWithPath: tool)
		task.arguments=arguments
		task.standardOutput=FileHandle.nullDevice
		task.standardError=FileHandle.nullDevice
		do{ try task.run() }catch{ return false }
		task.waitUntilExit()
		return task.terminationStatus==0
	}
}
