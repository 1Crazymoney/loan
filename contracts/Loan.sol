// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { IERC20 } from "../modules/erc20/src/interfaces/IERC20.sol";

import { ERC20Helper } from "../modules/erc20-helper/src/ERC20Helper.sol";

import { ILoan } from "./interfaces/ILoan.sol";

// could be collateral, drawableFunds, claimableFunds left 

/// @title Loan maintains all accounting and functionality related to Loans.
abstract contract Loan is ILoan {

    // Roles
    address public override borrower;
    address public override lender;

    // Assets
    address public override collateralAsset;
    address public override fundsAsset;

    // Static Loan Parameters
    uint256 public override endingPrincipal;
    uint256 public override gracePeriod;
    uint256 public override interestRate;
    uint256 public override lateFeeRate;
    uint256 public override paymentInterval;

    // Requests
    uint256 public override collateralRequired;
    uint256 public override principalRequired;

    // State
    uint256 public override drawableFunds;
    uint256 public override claimableFunds;
    uint256 public override collateral;
    uint256 public override nextPaymentDueDate;
    uint256 public override paymentsRemaining;
    uint256 public override principal;

    /********************************************/
    /*** External Virtual Borrowing Functions ***/
    /********************************************/

    function drawdownFunds(uint256 _amount, address _destination) external virtual override {
        require(msg.sender == borrower, "L:DF:NOT_BORROWER");
        _drawdownFunds(_amount, _destination);
    }

    function makePayment() external virtual override returns (uint256) {
        return _makePayment(uint256(1));
    }

    function makePayments(uint256 numberOfPayments) external virtual override returns (uint256) {
        return _makePayment(numberOfPayments);
    }

    function postCollateral() external virtual override returns (uint256) {
        return _postCollateral();
    }

    function removeCollateral(uint256 _amount, address _destination) external virtual override {
        require(msg.sender == borrower, "L:DF:NOT_BORROWER");
        _removeCollateral(_amount, _destination);
    }

    function returnFunds() external virtual override returns (uint256) {
        return _returnFunds();
    }

    /******************************************/
    /*** External Virtual Lending Functions ***/
    /******************************************/

    function claimFunds(uint256 _amount, address _destination) external virtual override {
        require(msg.sender == lender, "L:DF:NOT_LENDER");
        _claimFunds(_amount, _destination);
    }

    function lend(address _lender) external virtual override returns (uint256) {
        return _lend(_lender);
    }

    function repossess(address _collateralAssetDestination, address _fundsAssetDestination)
        external virtual override
        returns (uint256 collateralAssetAmount, uint256 fundsAssetAmount)
    {
        require(msg.sender == lender, "L:DF:NOT_LENDER");
        return _repossess(_collateralAssetDestination, _fundsAssetDestination);
    }

    /*********************************/
    /*** External Getter Functions ***/
    /*********************************/

    function getNextPaymentsBreakDown(uint256 numberOfPayments)
        external view virtual override
        returns (uint256 totalPrincipalAmount, uint256 totalInterestFees, uint256 totalLateFees)
    {
        return _getPaymentsBreakdown(
            numberOfPayments,
            block.timestamp,
            nextPaymentDueDate,
            paymentInterval,
            principal,
            endingPrincipal,
            interestRate,
            paymentsRemaining,
            lateFeeRate
        );
    }

    /*****************/
    /*** Modifiers ***/
    /*****************/

    modifier maintainsCollateral() {
        _;
        // Require that the final collateral ratio is commensurate with the amount of outstanding principal
        // uint256 outstandingPrincipal = principal > drawableFunds ? principal - drawableFunds : 0;
        // require(collateral / outstandingPrincipal >= collateralRequired / principalRequired, "L:INSUF_COLLATERAL");
        require(
            collateral * principalRequired >= collateralRequired * (principal > drawableFunds ? principal - drawableFunds : uint256(0)),
            "L:INSUF_COLLATERAL"
        );
    }

    modifier maintainsFunds() {
        _;
        // Require that the final funds balance of the loan is sufficient
        require(
            IERC20(fundsAsset).balanceOf(address(this)) >= drawableFunds + claimableFunds + (collateralAsset == fundsAsset ? collateral : uint256(0)),
            "L:INSUF_FUNDS"
        );
    }

    /*****************************************/
    /*** Internal State-Changing Functions ***/
    /*****************************************/

    /**
     *  @dev   Initializes the loan.
     *  @param _borrower   The address of the borrower.
     *  @param _assets     Array of asset addresses. 
     *                       [0]: collateralAsset, 
     *                       [1]: fundsAsset.
     *  @param _parameters Array of loan parameters: 
     *                       [0]: endingPrincipal, 
     *                       [1]: gracePeriod, 
     *                       [2]: interestRate, 
     *                       [3]: lateFeeRate, 
     *                       [4]: paymentInterval, 
     *                       [5]: paymentsRemaining.
     *  @param _requests   Requested amounts: 
     *                       [0]: collateralRequired, 
     *                       [1]: principalRequired.
     */
    function _initialize(address _borrower, address[2] memory _assets, uint256[6] memory _parameters, uint256[2] memory _requests) internal {
        borrower = _borrower;

        collateralAsset = _assets[0];
        fundsAsset      = _assets[1];

        endingPrincipal   = _parameters[0];
        gracePeriod       = _parameters[1];
        interestRate      = _parameters[2];
        lateFeeRate       = _parameters[3];
        paymentInterval   = _parameters[4];
        paymentsRemaining = _parameters[5];

        collateralRequired = _requests[0];
        principalRequired  = _requests[1];

        emit Initialized(_borrower, _assets, _parameters, _requests);
    }

    /**
     *  @dev Sends any unaccounted amount of an asset to an address.
     */
    function _skim(address _asset, address _destination) internal returns (uint256 amount) {
        amount = _asset == collateralAsset
            ? _getExtraCollateral()
            : _asset == fundsAsset
                ? _getExtraFunds()
                : IERC20(_asset).balanceOf(address(this));

        require(ERC20Helper.transfer(_asset, _destination, amount), "L:S:TRANSFER_FAILED");

        emit Skimmed(_asset, _destination, amount);
    }

    /**************************************/
    /*** Internal Borrow-side Functions ***/
    /**************************************/

    function _drawdownFunds(uint256 _amount, address _destination) internal maintainsCollateral {
        drawableFunds -= _amount;
        require(ERC20Helper.transfer(fundsAsset, _destination, _amount), "L:DF:TRANSFER_FAILED");
        emit FundsDrawnDown(_amount);
    }

    function _makePayment(uint256 numberOfPayments) internal returns (uint256 totalAmountPaid) {
        (uint256 totalPrincipalAmount, uint256 totalInterestFees, uint256 totalLateFees) = _getPaymentsBreakdown(
            numberOfPayments,
            block.timestamp,
            nextPaymentDueDate,
            paymentInterval,
            principal,
            endingPrincipal,
            interestRate,
            paymentsRemaining,
            lateFeeRate
        );

        // The drawable funds are increased by the extra funds in the contract, minus the total needed for payment
        drawableFunds = drawableFunds + _getExtraFunds() - (totalAmountPaid = (totalPrincipalAmount + totalInterestFees + totalLateFees));

        claimableFunds     += totalAmountPaid;
        nextPaymentDueDate += paymentInterval;
        principal          -= totalPrincipalAmount;
        paymentsRemaining  -= numberOfPayments;

        // TODO: How to ensure we don't end up with some principal remaining but no payments remaining?
        //       Perhaps force the last payment to include all outstanding principal, just in case _getPaymentsBreakdown produces a rounding error.

        emit PaymentsMade(numberOfPayments, totalPrincipalAmount, totalInterestFees, totalLateFees);
    }

    function _postCollateral() internal returns (uint256 amount) {
        collateral += (amount = _getExtraCollateral());
        emit CollateralPosted(amount);
    }

    function _removeCollateral(uint256 _amount, address _destination) internal maintainsCollateral {
        collateral -= _amount;
        require(ERC20Helper.transfer(collateralAsset, _destination, _amount), "L:RC:TRANSFER_FAILED");
        emit CollateralRemoved(_amount);
    }

    function _returnFunds() internal returns (uint256 amount) {
        drawableFunds += (amount = _getExtraFunds());
        emit FundsReturned(amount);
    }

    /************************************/
    /*** Internal Lend-side Functions ***/
    /************************************/

    function _claimFunds(uint256 _amount, address _destination) internal maintainsFunds {
        claimableFunds -= _amount;
        require(ERC20Helper.transfer(fundsAsset, _destination, _amount), "L:CF:TRANSFER_FAILED");
        emit FundsClaimed(_amount);
    }

    function _lend(address _lender) internal returns (uint256 amount) {
        require(nextPaymentDueDate == uint256(0) && paymentsRemaining > uint256(0),           "L:L:ALREADY_LENT");
        require(principalRequired == (drawableFunds = principal = amount = _getExtraFunds()), "L:L:INSUFFICIENT_AMOUNT");

        nextPaymentDueDate = block.timestamp + paymentInterval;
        emit Funded(lender = _lender, nextPaymentDueDate);
    }

    function _repossess(address _collateralAssetDestination, address _fundsAssetDestination)
        internal
        returns (uint256 collateralAssetAmount, uint256 fundsAssetAmount)
    {
        require(block.timestamp > nextPaymentDueDate + gracePeriod, "L:TD:NOT_IN_DEFAULT");

        // Transfer collateral and principal assets from the loan to the lender's destination of choice.
        collateralAssetAmount = IERC20(collateralAsset).balanceOf(address(this));

        if (collateralAssetAmount > uint256(0)) {
            require(ERC20Helper.transfer(collateralAsset, _collateralAssetDestination, collateralAssetAmount), "L:TD:COLLATERAL_TRANSFER_FAILED");
        }

        fundsAssetAmount = IERC20(fundsAsset).balanceOf(address(this));

        if (fundsAssetAmount > uint256(0)) {
            require(ERC20Helper.transfer(fundsAsset, _fundsAssetDestination, fundsAssetAmount), "L:TD:FUNDS_TRANSFER_FAILED");
        }

        drawableFunds      = uint256(0);
        claimableFunds     = uint256(0);
        collateral         = uint256(0);
        nextPaymentDueDate = uint256(0);
        principal          = uint256(0);
        paymentsRemaining  = uint256(0);

        emit Repossessed(collateralAssetAmount, fundsAssetAmount);
    }

    /****************************************/
    /*** Internal View Readonly Functions ***/
    /****************************************/

    /**
     *  @dev Returns the amount of collateralAsset above what has been currently accounted for.
     */
    function _getExtraCollateral() internal view returns (uint256) {
        return IERC20(collateralAsset).balanceOf(address(this))
            - collateral
            - (collateralAsset == fundsAsset ? drawableFunds + claimableFunds : uint256(0));
    }

    /**
     *  @dev Returns the amount of fundsAsset above what has been currently accounted for.
     */
    function _getExtraFunds() internal view returns (uint256) {
        return IERC20(fundsAsset).balanceOf(address(this))
            - drawableFunds
            - claimableFunds
            - (collateralAsset == fundsAsset ? collateral : uint256(0));
    }

    /****************************************/
    /*** Internal Pure Readonly Functions ***/
    /****************************************/

    /**
     *  @dev Returns the fee by applying an annualized fee rate over an interval of time.
     */
    function _getFee(uint256 _amount, uint256 _feeRate, uint256 _interval) internal pure returns (uint256) {
        return _amount * _getPeriodicFeeRate(_feeRate, _interval) / uint256(1_000_000);
    }

    /**
     *  @dev Returns principal and interest fee portions of a payment, given generic loan parameters.
     */
    function _getPayment(uint256 _principal, uint256 _endingPrincipal, uint256 _interestRate, uint256 _paymentInterval, uint256 _totalPayments)
        internal pure returns (uint256 principalAmount, uint256 interestAmount)
    {
        uint256 periodicRate = _getPeriodicFeeRate(_interestRate, _paymentInterval);
        uint256 raisedRate   = _scaledExponent(uint256(1_000_000) + periodicRate, _totalPayments, uint256(1_000_000));

        // TODO: Check if raisedRate can be <= 1_000_000

        uint256 total =
            (
                (
                    (
                        (
                            _principal * raisedRate
                        ) / uint256(1_000_000)
                    ) - _endingPrincipal
                ) * periodicRate
            ) / (raisedRate - uint256(1_000_000));

        principalAmount = total - (interestAmount = _getFee(_principal, _interestRate, _paymentInterval));
    }

    /**
     *  @dev Returns principal, interest fee, and late fee portions of a payment, given generic loan parameters and conditions.
     */
    function _getPaymentBreakdown(
        uint256 _paymentDate,
        uint256 _nextPaymentDueDate,
        uint256 _paymentInterval,
        uint256 _principal,
        uint256 _endingPrincipal,
        uint256 _interestRate,
        uint256 _paymentsRemaining,
        uint256 _lateFeeRate
    ) internal pure returns (uint256 principalAmount, uint256 interestFee, uint256 lateFee) {
        // Get the expected principal and interest portions for the payment, as if it was on-time
        (principalAmount, interestFee) = _getPayment(_principal, _endingPrincipal, _interestRate, _paymentInterval, _paymentsRemaining);

        // Determine how late the payment is
        uint256 secondsLate = _paymentDate > _nextPaymentDueDate ? _paymentDate - _nextPaymentDueDate : uint256(0);

        // Accumulate the potential late fees incurred on the expected interest portion
        lateFee = _getFee(interestFee, _lateFeeRate, secondsLate);

        // Accumulate the interest and potential additional interest incurred in the late period
        interestFee += _getFee(_principal, _interestRate, secondsLate);
    }

    /**
     *  @dev Returns accumulated principal, interest fee, and late fee portions of several payments, given generic loan parameters and conditions.
     */
    function _getPaymentsBreakdown(
        uint256 _numberOfPayments,
        uint256 _currentTime,
        uint256 _nextPaymentDueDate,
        uint256 _paymentInterval,
        uint256 _principal,
        uint256 _endingPrincipal,
        uint256 _interestRate,
        uint256 _paymentsRemaining,
        uint256 _lateFeeRate
    )
        internal pure 
        returns (uint256 totalPrincipalAmount, uint256 totalInterestFees, uint256 totalLateFees)
    {
        // For each payments (current and late)
        for (; _numberOfPayments > uint256(0); --_numberOfPayments) {
            (uint256 principalAmount, uint256 interestFee, uint256 lateFee) = _getPaymentBreakdown(
                _currentTime,
                _nextPaymentDueDate,
                _paymentInterval,
                _principal,
                _endingPrincipal,
                _interestRate,
                _paymentsRemaining--,
                _lateFeeRate
            );

            // Update local variables
            totalPrincipalAmount += principalAmount;
            totalInterestFees    += interestFee;
            totalLateFees        += lateFee;
            _nextPaymentDueDate  += _paymentInterval;
            _principal           -= principalAmount;
        }
    }

    /**
     *  @dev Returns the fee rate over an interval, given an annualized fee rate.
     */
    function _getPeriodicFeeRate(uint256 _feeRate, uint256 _interval) internal pure returns (uint256) {
        return (_feeRate * _interval) / uint256(365 days);
    }

    /**
     *  @dev Returns exponentiation of a scaled base value.
     */
    function _scaledExponent(uint256 base, uint256 exponent, uint256 one) internal pure returns (uint256) {
        return exponent == uint256(0) ? one : (base * _scaledExponent(base, exponent - uint256(1), one)) / one;
    }

}
