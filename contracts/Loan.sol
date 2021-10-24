// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import { BasicFundsTokenFDT }                    from "../modules/funds-distribution-token/contracts/BasicFundsTokenFDT.sol";
import { Context as ERC20Context }               from "../modules/funds-distribution-token/modules/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20, SafeERC20 }                     from "../modules/openzeppelin-contracts/contracts/token/ERC20/SafeERC20.sol";
import { Context as PauseableContext, Pausable } from "../modules/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { Util, IMapleGlobals }                   from "../modules/util/contracts/Util.sol";

import { LoanLib } from "./libraries/LoanLib.sol";

import { ILoan } from "./interfaces/ILoan.sol";

// NOTE: `IMapleGlobals as IMapleGlobalsLike` necessary for https://github.com/ethereum/solidity/issues/9278
import { ICollateralLockerLike, ILockerFactoryLike, IMapleGlobals as IMapleGlobalsLike } from "./interfaces/Interfaces.sol";

/// @title Loan maintains all accounting and functionality related to Loans.
contract Loan is ILoan, BasicFundsTokenFDT, Pausable {

    using SafeERC20 for IERC20;

    State public override loanState;

    address public override immutable liquidityAsset;
    address public override immutable collateralAsset;

    address public override immutable fundingLocker;
    address public override immutable flFactory;
    address public override immutable collateralLocker;
    address public override immutable clFactory;
    address public override           borrower;
    address public override           repaymentCalc;
    address public override           lateFeeCalc;
    address public override           premiumCalc;
    address public override immutable superFactory;

    uint256 public override nextPaymentDue;

    // Loan specifications
    uint256 public override           apr;
    uint256 public override           paymentsRemaining;
    uint256 public override           termDays;
    uint256 public override           paymentIntervalSeconds;
    uint256 public override           requestAmount;
    uint256 public override           collateralRatio;
    uint256 public override immutable createdAt;
    uint256 public override immutable fundingPeriod;
    uint256 public override           defaultGracePeriod;

    // Accounting variables
    uint256 public override principalOwed;
    uint256 public override principalPaid;
    uint256 public override interestPaid;
    uint256 public override feePaid;
    uint256 public override excessReturned;

    // Liquidation variables
    uint256 public override amountLiquidated;
    uint256 public override amountRecovered;
    uint256 public override defaultSuffered;
    uint256 public override liquidationExcess;

    // Refinance
    bytes32 public override refinanceCommitment;

    /**
        @dev    Constructor for a Loan.
        @dev    It emits a `LoanStateChanged` event.
        @param  _borrower        Will receive the funding when calling `drawdown()`. Is also responsible for repayments.
        @param  _liquidityAsset  The asset the Borrower is requesting funding in.
        @param  _collateralAsset The asset provided as collateral by the Borrower.
        @param  _flFactory       Factory to instantiate FundingLocker with.
        @param  _clFactory       Factory to instantiate CollateralLocker with.
        @param  specs            Contains specifications for this Loan.
                                     [0] => apr,
                                     [1] => termDays,
                                     [2] => paymentIntervalDays (aka PID),
                                     [3] => requestAmount,
                                     [4] => collateralRatio.
        @param  calcs            The calculators used for this Loan.
                                     [0] => repaymentCalc,
                                     [1] => lateFeeCalc,
                                     [2] => premiumCalc.
     */
    constructor(
        address _borrower,
        address _liquidityAsset,
        address _collateralAsset,
        address _flFactory,
        address _clFactory,
        uint256[5] memory specs,
        address[3] memory calcs
    ) BasicFundsTokenFDT("Maple Loan Token", "MPL-LOAN", _liquidityAsset) public {
        address globals = LoanLib.getGlobals(msg.sender);

        // Perform validity cross-checks.
        LoanLib.loanSanityChecks(globals, _liquidityAsset, _collateralAsset, specs);

        borrower  = _borrower;
        createdAt = block.timestamp;

        // Update state variables.
        apr                    = specs[0];
        paymentsRemaining      = (termDays = specs[1]).div(specs[2]);
        paymentIntervalSeconds = specs[2].mul(1 days);
        requestAmount          = specs[3];
        collateralRatio        = specs[4];
        fundingPeriod          = IMapleGlobalsLike(globals).fundingPeriod();
        defaultGracePeriod     = IMapleGlobalsLike(globals).defaultGracePeriod();
        repaymentCalc          = calcs[0];
        lateFeeCalc            = calcs[1];
        premiumCalc            = calcs[2];
        superFactory           = msg.sender;

        // Deploy lockers.
        collateralLocker = ILockerFactoryLike(clFactory = _clFactory).newLocker(collateralAsset = _collateralAsset);
        fundingLocker    = ILockerFactoryLike(flFactory = _flFactory).newLocker(liquidityAsset = _liquidityAsset);

        resetRefinanceCommitment();

        emit LoanStateChanged(State.Ready);
    }

    /**************************/
    /*** Borrower Functions ***/
    /**************************/

    function drawdown(uint256 amt) external override {
        uint256 fundingLockerBalance = LoanLib.drawdownChecks(
            superFactory,
            borrower,
            refinanceCommitment,
            liquidityAsset,
            fundingLocker,
            amt,
            requestAmount
        );

        // Update accounting variables for the Loan.
        principalOwed = principalOwed.add(amt);

        if (nextPaymentDue == uint256(0)) {
            nextPaymentDue = block.timestamp.add(paymentIntervalSeconds);
        }

        loanState = State.Active;

        address treasury;
        ( treasury, feePaid ) = LoanLib.handleDrawdown(
            superFactory,
            collateralAsset,
            borrower,
            collateralLocker,
            collateralRequiredForDrawdown(amt),
            amt,
            termDays,
            fundingLocker
        );

        requestAmount = uint256(0);

        // Update excessReturned for `claim()`.
        excessReturned = fundingLockerBalance.sub(feePaid);

        // Call `updateFundsReceived()` update LoanFDT accounting with funds received from fees and excess returned.
        updateFundsReceived();

        emit LoanStateChanged(State.Active);
        emit Drawdown(amt);
    }

    function makePayment() external override {
        LoanLib.makePaymentsChecks(superFactory, uint8(loanState));
        (uint256 total, uint256 principal, uint256 interest,, bool paymentLate) = getNextPayment();
        --paymentsRemaining;
        _makePayment(total, principal, interest, paymentLate);
    }

    function makeFullPayment() external override {
        LoanLib.makePaymentsChecks(superFactory, uint8(loanState));
        (uint256 total, uint256 principal, uint256 interest) = getFullPayment();
        paymentsRemaining = uint256(0);
        _makePayment(total, principal, interest, false);
    }

    /**
        @dev Updates the payment variables and transfers funds from the Borrower into the Loan.
        @dev It emits one or two `BalanceUpdated` events (depending if payments remaining).
        @dev It emits a `LoanStateChanged` event if no payments remaining.
        @dev It emits a `PaymentMade` event.
     */
    function _makePayment(uint256 total, uint256 principal, uint256 interest, bool paymentLate) internal {
        // Update internal accounting variables.
        interestPaid  = interestPaid.add(interest);
        principalPaid = principalPaid.add(principal);

        if (paymentsRemaining > uint256(0)) {
            // Update info related to next payment and, if needed, decrement principalOwed.
            nextPaymentDue = nextPaymentDue.add(paymentIntervalSeconds);
            principalOwed  = principalOwed.sub(principal);
        } else {
            // Update info to close loan.
            principalOwed  = uint256(0);
            loanState      = State.Matured;
            nextPaymentDue = uint256(0);

            // Transfer all collateral back to the Borrower.
            ICollateralLockerLike(collateralLocker).pull(borrower, _getCollateralLockerBalance());

            emit LoanStateChanged(State.Matured);
        }

        // Loan payer sends funds to the Loan.
        IERC20(liquidityAsset).safeTransferFrom(msg.sender, address(this), total);

        // Update FDT accounting with funds received from interest payment.
        updateFundsReceived();

        emit PaymentMade(
            total,
            principal,
            interest,
            paymentsRemaining,
            principalOwed,
            paymentsRemaining > 0 ? nextPaymentDue : 0,
            paymentLate
        );
    }

    function proposeNewTerms(bytes[] calldata calls) external override {
        _isValidBorrower();

        emit NewTermsProposed(refinanceCommitment = LoanLib.generateRefinanceCommitment(calls), calls);
    }

    /************************/
    /*** Lender Functions ***/
    /************************/

    function fundLoan(address mintTo, uint256 amt) whenNotPaused external override {
        LoanLib.fundLoanChecks(superFactory);

        if (loanState == State.Active && refinanceCommitment != bytes32(0)) {
            _isSoleLender(mintTo);
        } else {
            _isValidState(State.Ready);
            require(block.timestamp <= createdAt.add(fundingPeriod), "L:FUND_PERIOD_EXP");
        }

        if (amt > uint256(0)) {
            IERC20(liquidityAsset).safeTransferFrom(msg.sender, fundingLocker, amt);
            _mint(mintTo, LoanLib.toWad(amt, liquidityAsset));  // Mint WAD precision LoanFDTs to `mintTo` (i.e DebtLocker contract).
        }

        emit LoanFunded(mintTo, amt);
    }

    function unwind() external override {
        LoanLib.unwindChecks(superFactory, uint8(loanState));

        // Update accounting for `claim()` and transfer funds from FundingLocker to Loan.
        excessReturned = LoanLib.unwind(liquidityAsset, fundingLocker, createdAt, fundingPeriod);

        updateFundsReceived();

        // Transition state to `Expired`.
        loanState = State.Expired;
        emit LoanStateChanged(State.Expired);
    }

    function triggerDefault() external override {
        LoanLib.triggerDefaultChecks(superFactory, uint8(loanState), nextPaymentDue, defaultGracePeriod, balanceOf(msg.sender), totalSupply());

        // Pull the Collateral Asset from the CollateralLocker, swap to the Liquidity Asset, and hold custody of the resulting Liquidity Asset in the Loan.
        (amountLiquidated, amountRecovered) = LoanLib.liquidateCollateral(collateralAsset, liquidityAsset, superFactory, collateralLocker);

        if (amountRecovered <= principalOwed) {
            // Decrement `principalOwed` by `amountRecovered`, set `defaultSuffered` to the difference (shortfall from the liquidation).
            defaultSuffered = principalOwed = principalOwed.sub(amountRecovered);
        } else {
            // Set `principalOwed` to zero and return excess value from the liquidation back to the Borrower.
            liquidationExcess = amountRecovered.sub(principalOwed);
            principalOwed = 0;
            IERC20(liquidityAsset).safeTransfer(borrower, liquidationExcess);  // Send excess to the Borrower.
        }

        // Update LoanFDT accounting with funds received from the liquidation.
        updateFundsReceived();

        // Transition `loanState` to `Liquidated`
        emit LoanStateChanged(loanState = State.Liquidated);
        emit Liquidation(amountLiquidated, amountRecovered, liquidationExcess, defaultSuffered);
    }

    function acceptNewTerms(bytes[] calldata calls) external override {
        _isSoleLender(msg.sender);

        LoanLib.refinance(refinanceCommitment, calls);

        emit NewTermsAccepted(refinanceCommitment);

        resetRefinanceCommitment();
    }

    /*************************/
    /*** Refinance Setters ***/
    /*************************/

    function decreasePrincipal(uint256 amount) external {
        _isSelf();

        IERC20(liquidityAsset).transferFrom(borrower, address(this), amount);

        principalPaid = principalPaid.add(amount);
        principalOwed = principalOwed.sub(amount);
    }

    function increasePrincipal(uint256 amount) external {
        _isSelf();

        require(IERC20(liquidityAsset).balanceOf(fundingLocker) == amount);

        requestAmount = requestAmount.add(amount);
    }

    function setRepaymentCalc(address calc) external {
        _isSelf();
        repaymentCalc = calc;
    }

    function setLateFeeCalc(address calc) external {
        _isSelf();
        lateFeeCalc = calc;
    }

    function setPremiumCalc(address calc) external {
        _isSelf();
        premiumCalc = calc;
    }

    function setNextPaymentDue(uint256 date) external {
        _isSelf();
        nextPaymentDue = date;
    }

    function setApr(uint256 value) external {
        _isSelf();
        apr = value;
    }

    function setTermDays(uint256 value) external {
        _isSelf();
        termDays          = value;
        paymentsRemaining = value.mul(1 days).div(paymentIntervalSeconds);
    }

    function setPaymentIntervalDays(uint256 value) external {
        _isSelf();
        paymentIntervalSeconds = value.mul(1 days);
        paymentsRemaining      = termDays.div(value);
    }

    function setCollateralRatio(uint256 value) external {
        _isSelf();
        collateralRatio = value;
    }

    function setDefaultGracePeriod(uint256 value) external {
        _isSelf();
        defaultGracePeriod = value;
    }

    /***********************/
    /*** Pause Functions ***/
    /***********************/

    function pause() external override {
        _isValidBorrower();
        super._pause();
    }

    function unpause() external override {
        _isValidBorrower();
        super._unpause();
    }

    /**************************/
    /*** Governor Functions ***/
    /**************************/

    function reclaimERC20(address token) external override {
        LoanLib.reclaimERC20(token, liquidityAsset, superFactory);
    }

    /*********************/
    /*** FDT Functions ***/
    /*********************/

    function withdrawFunds() public override {
        LoanLib.whenProtocolNotPaused(superFactory);
        super.withdrawFunds();
    }

    /************************/
    /*** Getter Functions ***/
    /************************/

    function getExpectedAmountRecovered() external override view returns (uint256) {
        return Util.calcMinAmount(IMapleGlobals(address(LoanLib.getGlobals(superFactory))), collateralAsset, liquidityAsset, _getCollateralLockerBalance());
    }

    function getNextPayment() public override view returns (uint256, uint256, uint256, uint256, bool) {
        return LoanLib.getNextPayment(repaymentCalc, nextPaymentDue, lateFeeCalc);
    }

    function getFullPayment() public override view returns (uint256 total, uint256 principal, uint256 interest) {
        (total, principal, interest) = LoanLib.getFullPayment(repaymentCalc, nextPaymentDue, lateFeeCalc, premiumCalc);
    }

    function collateralRequiredForDrawdown(uint256 amt) public override view returns (uint256) {
        return LoanLib.collateralRequiredForDrawdown(collateralAsset, liquidityAsset, collateralRatio, LoanLib.getGlobals(superFactory), amt);
    }

    /************************/
    /*** Helper Functions ***/
    /************************/

    /**
        @dev Returns the CollateralLocker balance.
     */
    function _getCollateralLockerBalance() internal view returns (uint256) {
        return IERC20(collateralAsset).balanceOf(collateralLocker);
    }

    /**
        @dev   Checks that the current state of the Loan matches the provided state.
        @param _state Enum of desired Loan state.
     */
    function _isValidState(State _state) internal view {
        require(loanState == _state, "L:INV_STATE");
    }

    /**
        @dev Checks that `msg.sender` is the Borrower.
     */
    function _isValidBorrower() internal view {
        require(msg.sender == borrower, "L:INV_BORROWER");
    }

    function _isSoleLender(address account) internal view {
        require(balanceOf(account) > totalSupply(), "L:NOT_LENDER");
    }

    function _isSelf() internal view {
        require(msg.sender == address(this), "L:NOT_SELF");
    }

    function resetRefinanceCommitment() internal {
        refinanceCommitment = LoanLib.getEmptyRefinanceCommitment();
    }

    function _msgSender() internal view override(PauseableContext, ERC20Context) returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view override(PauseableContext, ERC20Context) returns (bytes memory) {
        return msg.data;
    }

}
