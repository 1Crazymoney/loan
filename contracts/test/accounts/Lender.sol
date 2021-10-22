// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { IMapleLoan } from "../../interfaces/IMapleLoan.sol";

import { LoanUser } from "./LoanUser.sol";

contract Lender is LoanUser {

    /************************/
    /*** Direct Functions ***/
    /************************/

    function loan_acceptNewTerms(address loan_, address refinancer_, bytes[] calldata calls_, uint256 amount_) external {
        IMapleLoan(loan_).acceptNewTerms(refinancer_, calls_, amount_);
    }

    function loan_claimFunds(address loan_, uint256 amount_, address destination_) external {
        IMapleLoan(loan_).claimFunds(amount_, destination_);
    }

    function loan_repossess(address loan_, address destination_) external returns ( uint256 collateralAssetAmount_, uint256 fundsAssetAmount_) {
        return IMapleLoan(loan_).repossess(destination_);
    }

    function loan_setLender(address loan_, address lender_) external {
        IMapleLoan(loan_).setLender(lender_);
    }

    /*********************/
    /*** Try Functions ***/
    /*********************/

    function try_loan_acceptNewTerms(address loan_, address refinancer_, bytes[] calldata calls_, uint256 amount_) external returns (bool ok_) {
        ( ok_, ) = loan_.call(abi.encodeWithSelector(IMapleLoan.acceptNewTerms.selector, refinancer_, calls_, amount_));
    }

    function try_loan_claimFunds(address loan_, uint256 amount_, address destination_) external returns (bool ok_) {
        ( ok_, ) = loan_.call(abi.encodeWithSelector(IMapleLoan.claimFunds.selector, amount_, destination_));
    }

    function try_loan_repossess(address loan_, address destination_) external returns (bool ok_) {
        ( ok_, ) = loan_.call(abi.encodeWithSelector(IMapleLoan.repossess.selector, destination_));
    }

    function try_loan_setLender(address loan_, address lender_) external returns (bool ok_) {
        ( ok_, ) = loan_.call(abi.encodeWithSelector(IMapleLoan.setLender.selector, lender_));
    }

}
