//
//  InboundNearbyConnection.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Foundation
import Network
import CryptoKit
import CommonCrypto
import System
import AppKit

import SwiftECC
import BigInt

class InboundNearbyConnection: NearbyConnection{
	
	private var currentState:State = .initial
	public var delegate:InboundNearbyConnectionDelegate?
	private var cipherCommitment:Data?
	
	private var textPayloadID:Int64=0
	private var destinationFolder:URL?
	/// Files that arrived in full; read once the connection has closed.
	private(set) var savedFiles:[URL]=[]

	enum State{
		case initial, receivedConnectionRequest, sentUkeyServerInit, receivedUkeyClientFinish, sentConnectionResponse, sentPairedKeyResult, receivedPairedKeyResult, waitingForUserConsent, receivingFiles, disconnected
	}
	
	override init(connection: NWConnection, id:String) {
		super.init(connection: connection, id: id)
	}
	
	override func handleConnectionClosure() {
		super.handleConnectionClosure()
		currentState = .disconnected
		do{
			try deletePartiallyReceivedFiles()
		}catch{
			print("Error deleting partially received files: \(error)")
		}
		DispatchQueue.main.async {
			self.delegate?.connectionWasTerminated(connection: self, error: self.lastError)
		}
	}
	
	override internal func processReceivedFrame(frameData:Data){
		do{
			switch currentState {
			case .initial:
				let frame=try Location_Nearby_Connections_OfflineFrame(serializedData: frameData)
				try processConnectionRequestFrame(frame)
			case .receivedConnectionRequest:
				let msg=try Securegcm_Ukey2Message(serializedData: frameData)
				ukeyClientInitMsgData=frameData
				try processUkey2ClientInit(msg)
			case .sentUkeyServerInit:
				let msg=try Securegcm_Ukey2Message(serializedData: frameData)
				try processUkey2ClientFinish(msg, raw: frameData)
			case .receivedUkeyClientFinish:
				let frame=try Location_Nearby_Connections_OfflineFrame(serializedData: frameData)
				try processConnectionResponseFrame(frame)
			default:
				let smsg=try Securemessage_SecureMessage(serializedData: frameData)
				try decryptAndProcessReceivedSecureMessage(smsg)
			}
		}catch{
			lastError=error
			print("Deserialization error: \(error) in state \(currentState)")
#if !DEBUG
			protocolError()
#endif
		}
	}
	
	override internal func processTransferSetupFrame(_ frame:Sharing_Nearby_Frame) throws{
		if frame.hasV1 && frame.v1.hasType, case .cancel = frame.v1.type {
			print("Transfer canceled")
			try sendDisconnectionAndDisconnect()
			return
		}
		switch currentState{
		case .sentConnectionResponse:
			try processPairedKeyEncryptionFrame(frame)
		case .sentPairedKeyResult:
			try processPairedKeyResultFrame(frame)
		case .receivedPairedKeyResult:
			try processIntroductionFrame(frame)
		default:
			print("Unexpected connection state in processTransferSetupFrame: \(currentState)")
			print(frame)
		}
	}
	
	override func isServer() -> Bool {
		return true
	}
	
	override func processFileChunk(frame: Location_Nearby_Connections_PayloadTransferFrame) throws{
		let id=frame.payloadHeader.id
		guard currentState == .receivingFiles else { throw NearbyError.protocolError("File data before the user accepted") }
		guard let fileInfo=transferredFiles[id] else { throw NearbyError.protocolError("File payload ID \(id) is not known") }
		let currentOffset=fileInfo.bytesTransferred
		let body=frame.payloadChunk.body
		guard frame.payloadChunk.offset==currentOffset else { throw NearbyError.protocolError("Invalid offset into file \(frame.payloadChunk.offset), expected \(currentOffset)") }
		guard currentOffset+Int64(body.count)<=fileInfo.meta.size else { throw NearbyError.protocolError("Transferred file size exceeds previously specified value") }
		if body.count>0{
			try openHandle(id).write(contentsOf: body)
			transferredFiles[id]!.bytesTransferred+=Int64(body.count)
			fileInfo.progress?.completedUnitCount=transferredFiles[id]!.bytesTransferred
		}
		// The last chunk may carry data too; and a file that ends short of its size is broken, not done.
		if (frame.payloadChunk.flags & 1)==1{
			guard transferredFiles[id]!.bytesTransferred==fileInfo.meta.size else { throw NearbyError.protocolError("File ended early") }
			try finishFile(id)
			if transferredFiles.isEmpty{
				if let folder=destinationFolder{
					NSWorkspace.shared.open(folder)
				}
				try sendDisconnectionAndDisconnect()
			}
		}
	}

	override func processBytesPayload(payload: Data, id: Int64) throws -> Bool {
		let isText=textPayloadID != 0 && id==textPayloadID
		guard isText || transferredFiles[id] != nil else { return false }
		// Only once the user accepted: before that, any device on the network could make the Mac open a link or write a file.
		guard currentState == .receivingFiles else { throw NearbyError.protocolError("Payload before the user accepted") }
		if isText{
			// Web links only: a file:// or app link from the phone mustn't open anything on the Mac.
			if let text=String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
			   let url=URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()){
				NSWorkspace.shared.open(url)
			}
			try sendDisconnectionAndDisconnect()
			return true
		}
		try openHandle(id).write(contentsOf: payload)
		transferredFiles[id]!.bytesTransferred=Int64(payload.count)
		try finishFile(id)
		try sendDisconnectionAndDisconnect()
		return true
	}

	/// Opened at its first chunk, not at accept: hundreds of photos opened at once would hit the open-file limit (256).
	private func openHandle(_ id:Int64) throws -> FileHandle{
		if let handle=transferredFiles[id]!.fileHandle{ return handle }
		let handle=try FileHandle(forWritingTo: transferredFiles[id]!.destinationURL)
		transferredFiles[id]!.fileHandle=handle
		return handle
	}

	private func finishFile(_ id:Int64) throws{
		try transferredFiles[id]!.fileHandle?.close()
		savedFiles.append(transferredFiles[id]!.destinationURL)
		transferredFiles[id]!.progress?.unpublish()
		transferredFiles.removeValue(forKey: id)
	}

	/// The name's last path part, without characters that trip up Finder: "../x" can't leave Downloads. Same rule as Drop.safeName on the TV.
	static func safeFileName(_ raw:String) -> String{
		let last=raw.split(whereSeparator: { $0=="/" || $0=="\\" }).last.map(String.init) ?? ""
		var scalars=String.UnicodeScalarView()
		for s in last.unicodeScalars{
			scalars.append(s.value<0x20 || ":*?\"<>|".unicodeScalars.contains(s) ? "_" : s)
		}
		var name=String(scalars).trimmingCharacters(in: .whitespaces)
		if name.allSatisfy({ $0=="." }){ name="file" }
		if name.count>120{
			let ext=(name as NSString).pathExtension
			name=(1...16).contains(ext.count) ? String(name.prefix(119-ext.count))+"."+ext : String(name.prefix(120))
		}
		return name
	}

	/// Room for [bytes] and 200 MB to spare, as on the TV; true when the volume doesn't say.
	private static func enoughSpace(_ bytes:Int64, at url:URL) -> Bool{
		guard let free=try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return true }
		return bytes+200*1024*1024<=free
	}
	
	private func processConnectionRequestFrame(_ frame:Location_Nearby_Connections_OfflineFrame) throws{
		guard frame.hasV1 && frame.v1.hasConnectionRequest && frame.v1.connectionRequest.hasEndpointInfo else { throw NearbyError.requiredFieldMissing("connectionRequest.endpointInfo") }
		guard case .connectionRequest = frame.v1.type else { throw NearbyError.protocolError("Unexpected frame type \(frame.v1.type)") }
		let endpointInfo=frame.v1.connectionRequest.endpointInfo
		guard endpointInfo.count>17 else { throw NearbyError.protocolError("Endpoint info too short") }
		let deviceNameLength=Int(endpointInfo[17])
		guard endpointInfo.count>=deviceNameLength+18 else { throw NearbyError.protocolError("Endpoint info too short to contain the device name") }
		guard let deviceName=String(data: endpointInfo[18..<(18+deviceNameLength)], encoding: .utf8) else { throw NearbyError.protocolError("Device name is not valid UTF-8") }
		let rawDeviceType:Int=Int(endpointInfo[0] & 7) >> 1
		remoteDeviceInfo=RemoteDeviceInfo(name: deviceName, type: RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType))
		currentState = .receivedConnectionRequest
	}
	
	private func processUkey2ClientInit(_ msg:Securegcm_Ukey2Message) throws{
		guard msg.hasMessageType, msg.hasMessageData else { throw NearbyError.requiredFieldMissing("clientInit ukey2message.type|data") }
		guard case .clientInit = msg.messageType else{
			sendUkey2Alert(type: .badMessageType)
			throw NearbyError.ukey2
		}
		let clientInit:Securegcm_Ukey2ClientInit
		do{
			clientInit=try Securegcm_Ukey2ClientInit(serializedData: msg.messageData)
		}catch{
			sendUkey2Alert(type: .badMessageData)
			throw NearbyError.ukey2
		}
		guard clientInit.version==1 else{
			sendUkey2Alert(type: .badVersion)
			throw NearbyError.ukey2
		}
		guard clientInit.random.count==32 else{
			sendUkey2Alert(type: .badRandom)
			throw NearbyError.ukey2
		}
		var found=false
		for commitment in clientInit.cipherCommitments{
			if case .p256Sha512 = commitment.handshakeCipher{
				found=true
				cipherCommitment=commitment.commitment
				break
			}
		}
		guard found else{
			sendUkey2Alert(type: .badHandshakeCipher)
			throw NearbyError.ukey2
		}
		guard clientInit.nextProtocol=="AES_256_CBC-HMAC_SHA256" else{
			sendUkey2Alert(type: .badNextProtocol)
			throw NearbyError.ukey2
		}
		
		let domain=Domain.instance(curve: .EC256r1)
		let (pubKey, privKey)=domain.makeKeyPair()
		publicKey=pubKey
		privateKey=privKey
		
		var serverInit=Securegcm_Ukey2ServerInit()
		serverInit.version=1
		serverInit.random=Data.randomData(length: 32)
		serverInit.handshakeCipher = .p256Sha512
		
		var pkey=Securemessage_GenericPublicKey()
		pkey.type = .ecP256
		pkey.ecP256PublicKey=Securemessage_EcP256PublicKey()
		pkey.ecP256PublicKey.x=Data(pubKey.w.x.asSignedBytes())
		pkey.ecP256PublicKey.y=Data(pubKey.w.y.asSignedBytes())
		serverInit.publicKey=try pkey.serializedData()
		
		var serverInitMsg=Securegcm_Ukey2Message()
		serverInitMsg.messageType = .serverInit
		serverInitMsg.messageData=try serverInit.serializedData()
		let serverInitData=try serverInitMsg.serializedData()
		ukeyServerInitMsgData=serverInitData
		sendFrameAsync(serverInitData)
		currentState = .sentUkeyServerInit
	}
	
	private func processUkey2ClientFinish(_ msg:Securegcm_Ukey2Message, raw:Data) throws{
		guard msg.hasMessageType, msg.hasMessageData else { throw NearbyError.requiredFieldMissing("clientFinish ukey2message.type|data") }
		guard case .clientFinish = msg.messageType else { throw NearbyError.ukey2 }
		
		var sha=SHA512()
		sha.update(data: raw)
		guard cipherCommitment==Data(sha.finalize()) else { throw NearbyError.ukey2 }
		
		let clientFinish=try Securegcm_Ukey2ClientFinished(serializedData: msg.messageData)
		guard clientFinish.hasPublicKey else {throw NearbyError.requiredFieldMissing("ukey2clientFinish.publicKey") }
		let clientKey=try Securemessage_GenericPublicKey(serializedData: clientFinish.publicKey)
		
		try finalizeKeyExchange(peerKey: clientKey)
		
		currentState = .receivedUkeyClientFinish
	}
	
	private func processConnectionResponseFrame(_ frame:Location_Nearby_Connections_OfflineFrame) throws{
		guard frame.hasV1, frame.v1.hasType else { throw NearbyError.requiredFieldMissing("offlineFrame.v1.type") }
		if case .connectionResponse = frame.v1.type {
			var resp=Location_Nearby_Connections_OfflineFrame()
			resp.version = .v1
			resp.v1=Location_Nearby_Connections_V1Frame()
			resp.v1.type = .connectionResponse
			resp.v1.connectionResponse=Location_Nearby_Connections_ConnectionResponseFrame()
			resp.v1.connectionResponse.response = .accept
			resp.v1.connectionResponse.status=0
			resp.v1.connectionResponse.osInfo=Location_Nearby_Connections_OsInfo()
			resp.v1.connectionResponse.osInfo.type = .apple
			sendFrameAsync(try resp.serializedData())
			
			encryptionDone=true
			
			var pairedEncryption=Sharing_Nearby_Frame()
			pairedEncryption.version = .v1
			pairedEncryption.v1=Sharing_Nearby_V1Frame()
			pairedEncryption.v1.type = .pairedKeyEncryption
			pairedEncryption.v1.pairedKeyEncryption=Sharing_Nearby_PairedKeyEncryptionFrame()
			// Presumably used for all the phone number stuff that no one needs anyway
			pairedEncryption.v1.pairedKeyEncryption.secretIDHash=Data.randomData(length: 6)
			pairedEncryption.v1.pairedKeyEncryption.signedData=Data.randomData(length: 72)
			try sendTransferSetupFrame(pairedEncryption)
			currentState = .sentConnectionResponse
		} else {
			print("Unhandled offline frame plaintext: \(frame)")
		}
	}
	
	private func processPairedKeyEncryptionFrame(_ frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyEncryption else { throw NearbyError.requiredFieldMissing("shareNearbyFrame.v1.pairedKeyEncryption") }
		var pairedResult=Sharing_Nearby_Frame()
		pairedResult.version = .v1
		pairedResult.v1=Sharing_Nearby_V1Frame()
		pairedResult.v1.type = .pairedKeyResult
		pairedResult.v1.pairedKeyResult=Sharing_Nearby_PairedKeyResultFrame()
		pairedResult.v1.pairedKeyResult.status = .unable
		try sendTransferSetupFrame(pairedResult)
		currentState = .sentPairedKeyResult
	}
	
	private func processPairedKeyResultFrame(_ frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasPairedKeyResult else { throw NearbyError.requiredFieldMissing("shareNearbyFrame.v1.pairedKeyResult") }
		currentState = .receivedPairedKeyResult
	}
	
	private func makeFileDestinationURL(_ initialDest:URL) -> URL{
		var dest=initialDest
		if FileManager.default.fileExists(atPath: dest.path){
			var counter=1
			var path:String
			let ext=dest.pathExtension
			let baseUrl=dest.deletingPathExtension()
			repeat{
				path="\(baseUrl.path) (\(counter))"
				if !ext.isEmpty{
					path+=".\(ext)"
				}
				counter+=1
			}while FileManager.default.fileExists(atPath: path)
			dest=URL(fileURLWithPath: path)
		}
		return dest
	}
	
	private func processIntroductionFrame(_ frame:Sharing_Nearby_Frame) throws{
		guard frame.hasV1, frame.v1.hasIntroduction else { throw NearbyError.requiredFieldMissing("shareNearbyFrame.v1.introduction") }
		currentState = .waitingForUserConsent
		if frame.v1.introduction.fileMetadata.count>0 && frame.v1.introduction.textMetadata.isEmpty{
			var downloadsDirectory=(try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)).resolvingSymlinksInPath()
			let total=frame.v1.introduction.fileMetadata.reduce(Int64(0)){ $0+max($1.size, 0) }
			guard InboundNearbyConnection.enoughSpace(total, at: downloadsDirectory) else {
				rejectTransfer(with: .notEnoughSpace)
				return
			}
			if frame.v1.introduction.fileMetadata.count>1{
				let dateFormatter=DateFormatter()
				dateFormatter.dateFormat="yyyy-MM-dd HH.mm.ss"
				let folderName="\(remoteDeviceInfo?.name ?? "Dropyk") \(dateFormatter.string(from: Date()))"
					.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
				downloadsDirectory=makeFileDestinationURL(downloadsDirectory.appendingPathComponent(folderName))
				destinationFolder=downloadsDirectory
			}
			for file in frame.v1.introduction.fileMetadata{
				guard file.size>=0 else { throw NearbyError.protocolError("Negative file size") }
				let name=InboundNearbyConnection.safeFileName(file.name)
				let dest=makeFileDestinationURL(downloadsDirectory.appendingPathComponent(name))
				let info=InternalFileInfo(meta: FileMetadata(name: name, size: file.size, mimeType: file.mimeType),
										  payloadID: file.payloadID,
										  destinationURL: dest)
				transferredFiles[file.payloadID]=info
			}
			let metadata=TransferMetadata(files: transferredFiles.map({$0.value.meta}), id: id, pinCode: pinCode)
			DispatchQueue.main.async {
				self.delegate?.obtainUserConsent(for: metadata, from: self.remoteDeviceInfo!, connection: self)
			}
		}else if frame.v1.introduction.textMetadata.count==1{
			let meta=frame.v1.introduction.textMetadata[0]
			if case .url=meta.type{
				let metadata=TransferMetadata(files: [], id: id, pinCode: pinCode, textDescription: meta.textTitle)
				textPayloadID=meta.payloadID
				DispatchQueue.main.async {
					self.delegate?.obtainUserConsent(for: metadata, from: self.remoteDeviceInfo!, connection: self)
				}
			}else if case .text=meta.type{
				let downloadsDirectory=(try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)).resolvingSymlinksInPath()
				let dateFormatter=DateFormatter()
				dateFormatter.dateFormat="yyyy-MM-dd HH.mm.ss"
				let dest=makeFileDestinationURL(downloadsDirectory.appendingPathComponent("\(dateFormatter.string(from: Date())).txt"))
				let info=InternalFileInfo(meta: FileMetadata(name: dest.lastPathComponent, size: meta.size, mimeType: "text/plain"),
										  payloadID: meta.payloadID,
										  destinationURL: dest)
				transferredFiles[meta.payloadID]=info
				DispatchQueue.main.async {
					self.delegate?.obtainUserConsent(for: TransferMetadata(files: [info.meta], id: self.id, pinCode: self.pinCode), from: self.remoteDeviceInfo!, connection: self)
				}
			}else{
				rejectTransfer(with: .unsupportedAttachmentType)
			}
		}else{
			rejectTransfer(with: .unsupportedAttachmentType)
		}
	}
	
	func submitUserConsent(accepted:Bool){
		// The connection's own queue: accepting touches the same state and sequence numbers as the incoming frames.
		NearbyConnection.dispatchQueue.async {
			if accepted{
				self.acceptTransfer()
			}else{
				self.rejectTransfer()
			}
		}
	}
	
	private func acceptTransfer(){
		do{
			if let folder=destinationFolder{
				try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			}
			for (id, file) in transferredFiles{
				guard FileManager.default.createFile(atPath: file.destinationURL.path, contents: nil) else { throw NearbyError.inputOutput }
				let progress=Progress()
				progress.fileURL=file.destinationURL
				progress.totalUnitCount=file.meta.size
				progress.kind = .file
				progress.isPausable=false
				progress.publish()
				transferredFiles[id]!.progress=progress
				transferredFiles[id]!.created=true
			}
			
			var frame=Sharing_Nearby_Frame()
			frame.version = .v1
			frame.v1.type = .response
			frame.v1.connectionResponse.status = .accept
			currentState = .receivingFiles
			try sendTransferSetupFrame(frame)
		}catch{
			lastError=error
			protocolError()
		}
	}
	
	private func rejectTransfer(with reason:Sharing_Nearby_ConnectionResponseFrame.Status = .reject){
		var frame=Sharing_Nearby_Frame()
		frame.version = .v1
		frame.v1.type = .response
		frame.v1.connectionResponse.status = reason
		do{
			try sendTransferSetupFrame(frame)
			try sendDisconnectionAndDisconnect()
		}catch{
			print("Error \(error)")
			protocolError()
		}
	}
	
	private func deletePartiallyReceivedFiles() throws{
		for (_, file) in transferredFiles{
			try? file.fileHandle?.close()
			guard file.created else { continue }
			try FileManager.default.removeItem(at: file.destinationURL)
		}
	}
}

protocol InboundNearbyConnectionDelegate{
	func obtainUserConsent(for transfer:TransferMetadata, from device:RemoteDeviceInfo, connection:InboundNearbyConnection)
	func connectionWasTerminated(connection:InboundNearbyConnection, error:Error?)
}
