// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;


import { MapleLoan } from "../../MapleLoan.sol";

contract MapleGlobalsMock {

    address public governor;

    constructor (address governor_) {
        governor = governor_;
    }

}

contract ConstructableMapleLoan is MapleLoan {

    constructor(address debtLocker_, address borrower_, address[2] memory assets_, uint256[6] memory parameters_, uint256[3] memory amounts_,  uint256[4] memory fees_) {
        _initializeLoan(debtLocker_, borrower_, assets_, parameters_, amounts_, fees_);
    }

}

contract DebtLockerMock {

    uint256 public treasuryFee   = 0;
    uint256 public investorFee   = 0;
    
    address public poolDelegate  = address(8);
    address public mapleTreasury = address(9);

}
