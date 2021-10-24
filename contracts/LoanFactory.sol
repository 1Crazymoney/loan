// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.11;

import { Pausable } from "../modules/openzeppelin-contracts/contracts/utils/Pausable.sol";

import { ILoanFactory }                       from "./interfaces/ILoanFactory.sol";
import { IMapleGlobals as IMapleGlobalsLike } from "./interfaces/Interfaces.sol";

import { Loan } from "./Loan.sol";

/// @title LoanFactory instantiates Loans.
contract LoanFactory is ILoanFactory, Pausable {

    uint8 public override constant CL_FACTORY = 0;
    uint8 public override constant FL_FACTORY = 2;

    uint8 public override constant INTEREST_CALC_TYPE = 10;
    uint8 public override constant LATEFEE_CALC_TYPE  = 11;
    uint8 public override constant PREMIUM_CALC_TYPE  = 12;

    address public override globals;

    uint256 public override loansCreated;

    mapping(uint256 => address) public override loans;
    mapping(address => bool)    public override isLoan;  // True only if a Loan was created by this factory.

    constructor(address _globals) public {
        globals = _globals;
    }

    function setGlobals(address newGlobals) external override {
        _isValidGovernor();
        globals = newGlobals;
    }

    function createLoan(
        address liquidityAsset,
        address collateralAsset,
        address flFactory,
        address clFactory,
        uint256[5] memory specs,
        address[3] memory calcs
    ) external override whenNotPaused returns (address loanAddress) {
        _whenProtocolNotPaused();

        // Perform validity checks.
        require(IMapleGlobalsLike(globals).isValidSubFactory(address(this), flFactory, FL_FACTORY), "LF:INV_FLF");
        require(IMapleGlobalsLike(globals).isValidSubFactory(address(this), clFactory, CL_FACTORY), "LF:INV_CLF");

        require(IMapleGlobalsLike(globals).isValidCalc(calcs[0], INTEREST_CALC_TYPE), "LF:INV_I_C");
        require(IMapleGlobalsLike(globals).isValidCalc(calcs[1],  LATEFEE_CALC_TYPE), "LF:INV_LF_C");
        require(IMapleGlobalsLike(globals).isValidCalc(calcs[2],  PREMIUM_CALC_TYPE), "LF:INV_P_C");

        // Deploy new Loan.
        Loan loan = new Loan(
            msg.sender,
            liquidityAsset,
            collateralAsset,
            flFactory,
            clFactory,
            specs,
            calcs
        );

        // Update the LoanFactory identification mappings.
        isLoan[loans[loansCreated++] = loanAddress = address(loan)] = true;

        emit LoanCreated(
            address(loan),
            msg.sender,
            liquidityAsset,
            collateralAsset,
            loan.collateralLocker(),
            loan.fundingLocker(),
            specs,
            calcs,
            loan.name(),
            loan.symbol()
        );
    }

    function pause() external override {
        _isValidGovernor();
        super._pause();
    }

    function unpause() external override {
        _isValidGovernor();
        super._unpause();
    }

    /**
        @dev Checks that `msg.sender` is the Governor.
     */
    function _isValidGovernor() internal view {
        require(msg.sender == IMapleGlobalsLike(globals).governor(), "LF:INV_GOV");
    }

    /**
        @dev Checks that the protocol is not in a paused state.
     */
    function _whenProtocolNotPaused() internal view {
        require(!IMapleGlobalsLike(globals).protocolPaused(), "LF:PROTO_PAUSED");
    }

}
