//
//  Currency.swift
//  BalanceForBlockchain
//
//  Created by Benjamin Baron on 6/14/17.
//  Copyright © 2017 Balanced Software, Inc. All rights reserved.
//

import Foundation

enum Currency: String {
    // Traditional
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    
    // Crypto
    case btc = "BTC"
    case ltc = "LTC"
    case eth = "ETH"
    
    // TODO: Don't hard code decimals for crypto
    var decimals: Int {
        switch self {
        case .btc, .ltc, .eth: return 8
        case .usd, .eur, .gbp: return 2
        default: return 8
        }
    }
    
    var symbol: String {
        switch self {
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"

        default: return self.rawValue + " "
        }
    }
}
