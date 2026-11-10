import Foundation

@_spi(BlobPreview) extension SyncEngine {
    /// The blob transfer service of a host-journal engine, opened on first use;
    /// nil in other modes or without durable storage. It is bound to the active
    /// group by the engine's sync cycle and retired before leave, removal or
    /// erase touches MLS state.
    public func blobTransfers() async -> BlobTransferService? {
        await openBlobService()
    }
}

extension SyncEngine {
    func openBlobService() async -> BlobTransferService? {
        if let blobService {
            return blobService
        }
        guard let blobDirectory else {
            return nil
        }
        let task = blobOpenTask ?? Task { [mailboxURL, endpointPolicy] in
            try? await BlobTransferService.open(directory: blobDirectory, relayURL: mailboxURL, policy: endpointPolicy)
        }
        blobOpenTask = task
        guard let service = await task.value else {
            if blobOpenTask == task {
                blobOpenTask = nil
            }
            return nil
        }
        if blobService == nil {
            blobService = service
            if blobRetirePending {
                blobRetirePending = false
                await service.retire()
            }
        }
        return blobService
    }

    /// Ends blob work of the current membership at once. Called before leave,
    /// removal, reset or erase changes MLS state.
    func retireBlobBinding() {
        blobBindingEpoch &+= 1
        if let blobService {
            blobService.retireNow()
        } else if blobDirectory != nil {
            blobRetirePending = true
        }
        retireSnapshotTransfers()
    }

    /// Binds the service to the session's group, unless a retirement happened
    /// while the membership was read.
    func bindBlobService(_ session: MLSSession) async {
        guard let service = await openBlobService() else {
            return
        }
        let epoch = blobBindingEpoch
        let token = service.bindingToken
        let client = session.client
        guard let access = try? await client.blobAccess(),
              let member = try? await client.fingerprint(),
              let route = try? BlobRoute(bytes: access.group),
              self.isCurrentBlobSession(session), blobBindingEpoch == epoch
        else {
            return
        }
        _ = try? await service.ensureBound(route: route, member: member, notRetiredSince: token) {
            try await client.blobAccess()
        }
        if snapshotService != nil || snapshotHooks != nil {
            await bindSnapshotService(session)
        }
    }
}
