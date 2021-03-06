//
//  Syncer.swift
//  Bal
//
//  Created by Benjamin Baron on 2/16/17.
//  Copyright © 2017 Balanced Software, Inc. All rights reserved.
//

import Foundation

class Syncer {
    fileprivate let gdaxApiClient = GDAXAPIClient(server: .production)
    
    fileprivate(set) var newInstitutionsOnly = false
    fileprivate(set) var syncing = false
    fileprivate(set) var canceled = false
    
    fileprivate var completionBlock: SuccessErrorsHandler?
    
    fileprivate var canceledBlock: CanceledBlock {
        return {
            return self.canceled
        }
    }
    
    func cancel() {
        canceled = true
    }
    
    func sync(newInstitutionsOnly: Bool = false, startDate: Date, pruneTransactions: Bool = false, completion: SuccessErrorsHandler?) {
        guard !syncing else {
            return
        }
        
        self.newInstitutionsOnly = newInstitutionsOnly
        self.syncing = true
        self.completionBlock = completion
        
        log.debug("Syncing started")
        NotificationCenter.postOnMainThread(name: Notifications.SyncStarted)
        
        let count = newInstitutionsOnly ? InstitutionRepository.si.allNewInstitutions().count : InstitutionRepository.si.institutionsCount
        if count > 0 {
            // First sync transaction categories so we have all categories in the database when
            // we sync transcations
            var success = true
            var errors = [Error]()
            PlaidApi.pullCategories { catSuccess, catError in
                if !catSuccess {
                    success = false
                    if let catError = catError {
                        errors.append(catError)
                    }
                }
                
                // Grab the institutions again in case we've added one while syncing categories or we've been canceled
                // and sort them as they're displayed in the UI
                let institutions = newInstitutionsOnly ? InstitutionRepository.si.allNewInstitutions(sorted: true) : InstitutionRepository.si.allInstitutions(sorted: true)
                
                if self.canceled {
                    self.cancelSync(errors: errors)
                } else if institutions.count == 0 {
                    self.completeSync(success: success, errors: errors)
                } else {
                    // Recursively sync the institutions (reversed because we use popLast)
                    self.syncInstitutions(institutions.reversed(), startDate: startDate, success: success, errors: errors, pruneTransactions: pruneTransactions)
                }
            }
        } else {
            self.completeSync(success: true, errors: [Error]())
        }
    }

    // Recursively iterate through the institutions, syncing one at a time
    fileprivate func syncInstitutions(_ institutions: [Institution], startDate: Date, success: Bool, errors: [Error], pruneTransactions: Bool = false) {
        var syncingInstitutions = institutions
        
        if !canceled, let institution = syncingInstitutions.popLast() {
            if institution.passwordInvalid {
                // Institution needs a PATCH, so skip
                log.error("Tried to sync institution \(institution.institutionId) (\(institution.sourceInstitutionId)): \(institution.name) but the password was invalid")
                syncInstitutions(syncingInstitutions, startDate: startDate, success: success, errors: errors, pruneTransactions: pruneTransactions)
            } else if institution.accessToken == nil && (institution.source == .plaid || institution.source == .coinbase) {
                // No access token somehow, so move on to the next one
                log.severe("Tried to sync institution \(institution.institutionId) (\(institution.sourceInstitutionId)): \(institution.name) but did not find an access token")
                syncInstitutions(syncingInstitutions, startDate: startDate, success: success, errors: errors, pruneTransactions: pruneTransactions)
            } else if institution.source == .coinbase && institution.isTokenExpired {
                if institution.refreshToken == nil {
                    // No refresh token somehow, so move on to the next one
                    log.severe("Tried to refresh access token for institution \(institution.institutionId) (\(institution.sourceInstitutionId)): \(institution.name) but did not find a refresh token")
                    syncInstitutions(syncingInstitutions, startDate: startDate, success: success, errors: errors, pruneTransactions: pruneTransactions)
                } else {
                    // Refresh the token
                    CoinbaseApi.refreshAccessToken(institution: institution) { success, error in
                        if success {
                            self.syncAccountsAndTransactions(institution: institution, remainingInstitutions: syncingInstitutions, startDate: startDate, success: success, errors: errors, pruneTransactions: pruneTransactions)
                        } else {
                            log.error("Failed to refresh token for institution \(institution.institutionId) (\(institution.sourceInstitutionId)): \(institution.name)")
                            NotificationCenter.postOnMainThread(name: Notifications.SyncError, object: institution,  userInfo: nil)
                            self.syncInstitutions(syncingInstitutions, startDate: startDate, success: success, errors: errors, pruneTransactions: pruneTransactions)
                        }
                    }
                }
            } else if institution.accessToken != nil  {
                // Valid institution, so sync it
                syncAccountsAndTransactions(institution: institution, remainingInstitutions: syncingInstitutions, startDate: startDate, success: success, errors: errors, pruneTransactions: pruneTransactions)
            } else if institution.source == .poloniex {
                if let apiKey = institution.apiKey, let secret = institution.secret {
                    syncPoloniexAccountsAndTransactions(secret: secret, key: apiKey, institution: institution, remainingInstitutions: syncingInstitutions, startDate: startDate, success: success, errors: errors)
                } else {
                    //logout and ask for resync
                    log.error("Failed get api and key for \(institution.institutionId) (\(institution.sourceInstitutionId)): \(institution.name)")
                }
            }
        } else {
            // No more institutions
            completeSync(success: success, errors: errors)
        }
    }
    
    fileprivate func syncAccountsAndTransactions(institution: Institution, remainingInstitutions: [Institution], startDate: Date, success: Bool, errors: [Error], pruneTransactions: Bool = false) {
        var syncingSuccess = success
        var syncingErrors = errors
        
        let userInfo = Notifications.userInfoForInstitution(institution)
        NotificationCenter.postOnMainThread(name: Notifications.SyncingInstitution, object: nil, userInfo: userInfo)
        
        log.debug("Pulling accounts and transactions for \(institution)")
        
        // Perform next sync handler
        let performNextSyncHandler = { (_ remainingInstitutions: [Institution], _ startDate: Date, _ syncingSuccess: Bool, _ syncingErrors: [Error]) -> Void in
            if self.canceled {
                self.cancelSync(errors: syncingErrors)
                return
            }
            
            self.syncInstitutions(remainingInstitutions, startDate: startDate, success: syncingSuccess, errors: syncingErrors, pruneTransactions: pruneTransactions)
        }
        
        // Perform sync
        switch institution.source {
        case .plaid:
            PlaidApi.pullAccountsAndTransactions(institution: institution, startDate: startDate, pruneTransactions: pruneTransactions, canceled: self.canceledBlock) { transSuccess, transError in
                
                if !transSuccess {
                    syncingSuccess = false
                    if let transError = transError {
                        syncingErrors.append(transError)
                        log.error("Error pulling transactions for \(institution): \(transError)")
                    }
                }
                log.debug("Finished pulling accounts and transactions for \(institution)")
                
                performNextSyncHandler(remainingInstitutions, startDate, syncingSuccess, syncingErrors)
            }
        case .coinbase:
            CoinbaseApi.updateAccounts(institution: institution) { success, error in
                if !success {
                    syncingSuccess = false
                    if let error = error {
                        syncingErrors.append(error)
                        log.error("Error pulling accounts for \(institution): \(error)")
                    }
                    log.debug("Finished pulling accounts for \(institution)")
                }
                
                performNextSyncHandler(remainingInstitutions, startDate, syncingSuccess, syncingErrors)
            }
        case .gdax:
            guard let accessToken = institution.accessToken else {
                syncingSuccess = false
                performNextSyncHandler(remainingInstitutions, startDate, syncingSuccess, syncingErrors)
                return
            }
            
            // Load credentials
            do {
                let credentials = try GDAXAPIClient.Credentials(identifier: accessToken)
                
                // Fetch data from GDAX
                self.gdaxApiClient.credentials = credentials
                try! self.gdaxApiClient.fetchAccounts { accounts, error in
                    guard let unwrappedAccounts = accounts else
                    {
                        if let unwrappedError = error
                        {
                            syncingErrors.append(unwrappedError)
                        }
                        
                        syncingSuccess = false
                        performNextSyncHandler(remainingInstitutions, startDate, syncingSuccess, syncingErrors)
                        return
                    }
                    
                    for account in unwrappedAccounts {
                        let decimals = Currency.rawValue(shortName: account.currencyCode).decimals
                        
                        // Calculate the integer value of the balance based on the decimals
                        var balance = Decimal(account.balance)
                        balance = balance * Decimal(pow(10.0, Double(decimals)))
                        let currentBalance = (balance as NSDecimalNumber).intValue
                        
                        balance = Decimal(account.availableBalance)
                        balance = balance * Decimal(pow(10.0, Double(decimals)))
                        let availableBalance = (balance as NSDecimalNumber).intValue
                        
                        // Initialize an Account object to insert the record
                        AccountRepository.si.account(institutionId: institution.institutionId, source: institution.source, sourceAccountId: account.identifier, sourceInstitutionId: "", accountTypeId: .exchange, accountSubTypeId: nil, name: account.currencyCode, currency: account.currencyCode, currentBalance: currentBalance, availableBalance: availableBalance, number: nil, altCurrency: nil, altCurrentBalance: nil, altAvailableBalance: nil)
                    }
                    
                    performNextSyncHandler(remainingInstitutions, startDate, syncingSuccess, syncingErrors)
                }
            } catch {
                syncingErrors.append(error)
                performNextSyncHandler(remainingInstitutions, startDate, syncingSuccess, syncingErrors)
                return
            }
        default:
            break
        }
    }
    
    fileprivate func syncPoloniexAccountsAndTransactions(secret: String, key: String, institution: Institution, remainingInstitutions: [Institution], startDate: Date, success: Bool, errors: [Error]) {
        var syncingSuccess = success
        var syncingErrors = errors
        
        let userInfo = Notifications.userInfoForInstitution(institution)
        NotificationCenter.postOnMainThread(name: Notifications.SyncingInstitution, object: nil, userInfo: userInfo)
        log.debug("Pulling accounts and transactions for \(institution)")
        
        //sync Poloniex
        let poloniexApi = PoloniexApi(secret: secret, key: key)
        poloniexApi.fetchBalances(institution: institution) { success, error in
            if !success {
                syncingSuccess = false
                if let error = error {
                    syncingErrors.append(error)
                    log.error("Error pulling accounts for \(institution): \(error)")
                }
                log.debug("Finished pulling accounts for \(institution)")
            }
            
            if self.canceled {
                self.cancelSync(errors: syncingErrors)
                return
            }
            self.syncInstitutions(remainingInstitutions, startDate: startDate, success: syncingSuccess, errors: syncingErrors)
        }
    }
    
    fileprivate func cancelSync(errors: [Error]) {
        completeSync(success: false, errors: errors)
    }
    
    fileprivate func completeSync(success: Bool, errors: [Error]) {
        async {
            // Call the completion block
            self.completionBlock?(success, errors)
            self.completionBlock = nil
            
            // Done syncing
            self.syncing = false
            
            log.debug("Syncing completed")
        }
    }
}

class MockSyncer: Syncer {
    override func sync(newInstitutionsOnly: Bool, startDate: Date, pruneTransactions: Bool, completion: SuccessErrorsHandler?) {
        guard !syncing else {
            return
        }
        
        syncing = true
        NotificationCenter.postOnMainThread(name: Notifications.SyncStarted)
        
        DispatchQueue.userInteractive.async(after: 3.0) {
            self.syncing = false
            async { completion?(true, nil) }
        }
    }
}
