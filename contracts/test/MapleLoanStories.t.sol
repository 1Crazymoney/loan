// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { TestUtils, Hevm, StateManipulations } from "../../modules/contract-test-utils/contracts/test.sol";
import { IERC20 }                              from "../../modules/erc20/src/interfaces/IERC20.sol";
import { MockERC20 }                           from "../../modules/erc20/src/test/mocks/MockERC20.sol";

import { ConstructableMapleLoan, LenderMock, IMapleLoan } from "./mocks/Mocks.sol";

import { Borrower } from "./accounts/Borrower.sol";

contract MapleLoanTest is StateManipulations, TestUtils {

    struct LoanState {
        address borrower;
        uint256 claimableFunds;
        uint256 collateral;
        address collateralAsset;
        uint256 collateralRequired;
        uint256 drawableFunds;
        uint256 earlyFee;
        uint256 earlyFeeRate;
        uint256 earlyInterestRateDiscount;
        uint256 endingPrincipal;
        address fundsAsset;
        uint256 gracePeriod;
        uint256 interestRate;
        uint256 lateFee;
        uint256 lateFeeRate;
        uint256 lateInterestRatePremium;
        address lender;
        uint256 nextPaymentDueDate;
        uint256 paymentInterval;
        uint256 paymentsRemaining;
        uint256 principalRequested;
        uint256 principal;
    }

    function assert_loan_state(IMapleLoan loan, LoanState memory state_) internal {
        assertEq(loan.borrower(),                  state_.borrower,                  "Incorrect Borrower");
        assertEq(loan.claimableFunds(),            state_.claimableFunds,            "Incorrect claimable funds");
        assertEq(loan.collateral(),                state_.collateral,                "Incorrect collateral");
        assertEq(loan.collateralAsset(),           state_.collateralAsset,           "Incorrect collateral asset");
        assertEq(loan.collateralRequired(),        state_.collateralRequired,        "Incorrect collateral required");
        assertEq(loan.drawableFunds(),             state_.drawableFunds,             "Incorrect drawable funds");
        assertEq(loan.earlyFee(),                  state_.earlyFee,                  "Incorrect early fee");
        assertEq(loan.earlyFeeRate(),              state_.earlyFeeRate,              "Incorrect early fee rate");
        assertEq(loan.earlyInterestRateDiscount(), state_.earlyInterestRateDiscount, "Incorrect early interest rate discount");
        assertEq(loan.endingPrincipal(),           state_.endingPrincipal,           "Incorrect ending principal");
        assertEq(loan.fundsAsset(),                state_.fundsAsset,                "Incorrect funds asset");
        assertEq(loan.gracePeriod(),               state_.gracePeriod,               "Incorrect grace period");
        assertEq(loan.interestRate(),              state_.interestRate,              "Incorrect interest rate");
        assertEq(loan.lateFee(),                   state_.lateFee,                   "Incorrect late fee");
        assertEq(loan.lateFeeRate(),               state_.lateFeeRate,               "Incorrect late fee rate");
        assertEq(loan.lateInterestRatePremium(),   state_.lateInterestRatePremium,   "Incorrect late interest rate premium");
        assertEq(loan.lender(),                    state_.lender,                    "Incorrect lender");
        assertEq(loan.nextPaymentDueDate(),        state_.nextPaymentDueDate,        "Incorrect next payment due date");
        assertEq(loan.paymentInterval(),           state_.paymentInterval,           "Incorrect payment interval");
        assertEq(loan.paymentsRemaining(),         state_.paymentsRemaining,         "Incorrect payments remaining");
        assertEq(loan.principalRequested(),        state_.principalRequested,        "Incorrect principal requested");
        assertEq(loan.principal(),                 state_.principal,                 "Incorrect principal");
    }

    function createDefaultState(address borrower, uint256[6] memory parameters_, uint256[3] memory amounts_, uint256[4] memory fees_, address[2] memory assets_) internal returns (LoanState memory) {
        LoanState memory defaultState =  LoanState ({
            borrower: borrower,
            claimableFunds: uint256(0),
            collateral: uint256(0),
            collateralAsset: assets_[0],
            collateralRequired: amounts_[0],
            drawableFunds: uint256(0),
            earlyFee: fees_[0],
            earlyFeeRate: fees_[1],
            earlyInterestRateDiscount: parameters_[4],
            endingPrincipal: amounts_[2],
            fundsAsset: assets_[1],
            gracePeriod: parameters_[0],
            interestRate: parameters_[3],
            lateFee: fees_[2],
            lateFeeRate: fees_[3],
            lateInterestRatePremium: parameters_[5],
            lender: address(0),
            nextPaymentDueDate: uint256(0),
            paymentInterval: parameters_[1],
            paymentsRemaining: parameters_[2],
            principalRequested: amounts_[1],
            principal: uint256(0)
        });

        return defaultState;
    }

    function updateLoanState(
        LoanState memory state_,
        uint256 claimableFunds_,
        uint256 collateral_,
        uint256 drawableFunds_,
        address lender_,
        uint256 nextPaymentDueDate_,
        uint256 principal_,
        uint256 paymentsRemaining_
    ) internal returns(LoanState memory) {
        state_.claimableFunds     = claimableFunds_;
        state_.drawableFunds      = drawableFunds_;
        state_.collateral         = collateral_;
        state_.lender             = lender_;
        state_.nextPaymentDueDate = nextPaymentDueDate_;
        state_.principal          = principal_;
        state_.paymentsRemaining  = paymentsRemaining_;
        return state_;
    }

    function getTotalFees(uint256 amountFunded_, LenderMock lender_, IMapleLoan loan_) internal returns(uint256) {
        return (((amountFunded_ * lender_.treasuryFee() * loan_.paymentInterval() * loan_.paymentsRemaining()) / (uint256(10_000) * uint256(365 days))) +
        ((amountFunded_ * lender_.investorFee() * loan_.paymentInterval() * loan_.paymentsRemaining()) / (uint256(10_000) * uint256(365 days))));
    }

    function test_story_fullyAmortized() external {
        Borrower   borrower = new Borrower();
        LenderMock lender   = new LenderMock();
        MockERC20  token    = new MockERC20("Test", "TST", 0);

        token.mint(address(borrower), 1_000_000);
        token.mint(address(lender),   1_000_000);

        ConstructableMapleLoan loan;
        LoanState memory loanState;

        {
            address[2] memory assets = [address(token), address(token)];

            uint256[6] memory parameters = [
                uint256(10 days),
                uint256(365 days / 6),
                uint256(6),
                uint256(0.12 ether),
                uint256(0.10 ether),
                uint256(0 ether)
            ];

            uint256[3] memory amounts = [uint256(300_000), uint256(1_000_000), uint256(0)];
            uint256[4] memory fees    = [uint256(0), uint256(0), uint256(0), uint256(0)];

            loan      = new ConstructableMapleLoan(address(borrower), assets, parameters, amounts, fees);

            loanState = createDefaultState(address(borrower), parameters, amounts, fees, assets);
        }

        IMapleLoan mockLoan = IMapleLoan(address(loan));

        assert_loan_state(mockLoan, loanState);

        // Fund via a 500k approval and a 500k transfer, totaling 1M
        lender.erc20_transfer(address(token), address(loan), 500_000);
        lender.erc20_approve(address(token), address(loan),  500_000);

        assertTrue(lender.try_loan_fundLoan(address(loan), address(lender), 500_000), "Cannot lend");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     uint256(0),
                    collateral_:         uint256(0),
                    drawableFunds_:      1_000_000 - getTotalFees(1_000_000, lender, mockLoan),
                    lender_:             address(lender),
                    nextPaymentDueDate_: block.timestamp + mockLoan.paymentInterval(),
                    principal_:          1_000_000,
                    paymentsRemaining_:  mockLoan.paymentsRemaining()
            });
            assert_loan_state(mockLoan, updatedState);
        }

        borrower.erc20_transfer(address(token), address(loan), 300_000);

        assertTrue(borrower.try_loan_postCollateral(address(loan)), "Cannot post");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     uint256(0),
                    collateral_:         300_000,
                    drawableFunds_:      1_000_000 - getTotalFees(1_000_000, lender, mockLoan),
                    lender_:             address(lender),
                    nextPaymentDueDate_: block.timestamp + mockLoan.paymentInterval(),
                    principal_:          1_000_000,
                    paymentsRemaining_:  mockLoan.paymentsRemaining()
            });
            assert_loan_state(mockLoan, updatedState);
        }

        assertTrue(borrower.try_loan_drawdownFunds(address(loan), 1_000_000, address(borrower)), "Cannot drawdown");

        { 
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     uint256(0),
                    collateral_:         300_000,
                    drawableFunds_:      uint256(0),
                    lender_:             address(lender),
                    nextPaymentDueDate_: block.timestamp + mockLoan.paymentInterval(),
                    principal_:          1_000_000,
                    paymentsRemaining_:  mockLoan.paymentsRemaining()
            });
            assert_loan_state(mockLoan, updatedState);
        }

        uint256 currentNextPaymentDueDate = mockLoan.nextPaymentDueDate();

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion, uint256 adminFee, uint256 serviceFee ) = loan.getNextPaymentsBreakDownWithFee(1);

        assertEq(principalPortion,         158_525,   "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(serviceFee + adminFee,    0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 6,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #1 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #1
        borrower.erc20_transfer(address(token), address(loan), 178_526);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {
            address lender_ = address(lender);

            serviceFee = principalPortion + interestPortion + serviceFee - adminFee;

            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     serviceFee,
                    collateral_:         300_000,
                    drawableFunds_:      uint256(1),
                    lender_:             lender_,
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          1_000_000 - principalPortion,
                    paymentsRemaining_:  5
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #2
        (principalPortion, interestPortion, adminFee, serviceFee ) = loan.getNextPaymentsBreakDownWithFee(1);

        assertEq(principalPortion,         161_696, "Different principal");
        assertEq(interestPortion,          16_829,  "Different interest");
        assertEq(serviceFee + adminFee,    0,       "Different late fees");
        assertEq(loan.paymentsRemaining(), 5,       "Different payments remaining");
        assertEq(loan.principal(),         841_475, "Different payments remaining");

        // Warp to 1 second before payment #2 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #2
        borrower.erc20_transfer(address(token), address(loan), 178_526);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {
            address lender_ = address(lender);
            
            serviceFee = principalPortion + interestPortion + serviceFee - adminFee;

            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     178_525 + serviceFee,
                    collateral_:         300_000,
                    drawableFunds_:      uint256(2),
                    lender_:             lender_,
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          841_475 - principalPortion,
                    paymentsRemaining_:  4
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #3
        ( principalPortion, interestPortion, adminFee, serviceFee ) = loan.getNextPaymentsBreakDownWithFee(1);

        assertEq(principalPortion,         164_930, "Different principal");
        assertEq(interestPortion,          13_595,  "Different interest");
        assertEq(adminFee + serviceFee,    0,       "Different late fees");
        assertEq(loan.paymentsRemaining(), 4,       "Different payments remaining");
        assertEq(loan.principal(),         679_779, "Different payments remaining");

        // Warp to 1 second before payment #3 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #3
        borrower.erc20_transfer(address(token), address(loan), 178_525);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        // Remove some collateral
        assertTrue(borrower.try_loan_removeCollateral(address(loan), 145_545, address(borrower)), "Cannot remove collateral");

        {   
            address lender_ = address(lender);
        
            serviceFee = principalPortion + interestPortion + serviceFee - adminFee;

            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     178_525 + 178_525 + serviceFee,
                    collateral_:         154_455,
                    drawableFunds_:      uint256(2),
                    lender_:             lender_,
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          679_779 - principalPortion,
                    paymentsRemaining_:  3
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #4
        ( principalPortion, interestPortion, adminFee, serviceFee ) = loan.getNextPaymentsBreakDownWithFee(1);

        assertEq(principalPortion,         168_230, "Different principal");
        assertEq(interestPortion,          10_296,  "Different interest");
        assertEq(adminFee + serviceFee,    0,       "Different late fees");
        assertEq(loan.paymentsRemaining(), 3,       "Different payments remaining");
        assertEq(loan.principal(),         514_849, "Different payments remaining");

        // Warp to 1 second before payment #4 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #4
        borrower.erc20_transfer(address(token), address(loan), 178_525);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        // Return some funds and remove some collateral
        borrower.erc20_transfer(address(token), address(loan), 150_000);

        assertTrue(borrower.try_loan_returnFunds(address(loan)), "Cannot return funds");

        assertEq(loan.drawableFunds(), 150_001, "Different drawable funds");

        assertTrue(borrower.try_loan_removeCollateral(address(loan), 85_059, address(borrower)), "Cannot remove collateral");

        assertEq(loan.collateral(), 69_396, "Different collateral");

        // Claim loan proceeds thus far
        assertTrue(lender.try_loan_claimFunds(address(loan), 714_101, address(lender)), "Cannot claim funds");

        {   
            address lender_ = address(lender);
    
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     uint256(0),
                    collateral_:         69_396,
                    drawableFunds_:      150_001,
                    lender_:             lender_,
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          514_849 - principalPortion,
                    paymentsRemaining_:  2
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #5
        ( principalPortion, interestPortion, adminFee, serviceFee ) = loan.getNextPaymentsBreakDownWithFee(1);

        assertEq(principalPortion,         171_593, "Different principal");
        assertEq(interestPortion,          6_932,   "Different interest");
        assertEq(adminFee + serviceFee,    0,       "Different late fees");
        assertEq(loan.paymentsRemaining(), 2,       "Different payments remaining");
        assertEq(loan.principal(),         346_619, "Different payments remaining");

        // Warp to 1 second before payment #5 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #5
        borrower.erc20_transfer(address(token), address(loan), 178_525);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");
        
        {   
            address lender_ = address(lender);

            serviceFee = principalPortion + interestPortion + serviceFee - adminFee;
            
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     serviceFee,
                    collateral_:         69_396,
                    drawableFunds_:      150_001,
                    lender_:             lender_,
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          346_619 - principalPortion,
                    paymentsRemaining_:  1
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #6
        ( principalPortion, interestPortion, adminFee, serviceFee ) = loan.getNextPaymentsBreakDownWithFee(1);

        assertEq(principalPortion,         175_026, "Different principal");
        assertEq(interestPortion,          3_500,   "Different interest");
        assertEq(adminFee + serviceFee,    0,       "Different late fees");
        assertEq(loan.paymentsRemaining(), 1,       "Different payments remaining");
        assertEq(loan.principal(),         175_026, "Different payments remaining");

        // Warp to 1 second before payment #6 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #6
        borrower.erc20_transfer(address(token), address(loan), 178_525);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {
            address lender_ = address(lender);

            serviceFee = principalPortion + interestPortion + serviceFee - adminFee;

            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     178_525 + serviceFee,
                    collateral_:         69_396,
                    drawableFunds_:      150_000,
                    lender_:             lender_,
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          175_026 - principalPortion,
                    paymentsRemaining_:  0
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Remove rest of available funds and collateral
        assertTrue(borrower.try_loan_drawdownFunds(address(loan), 150_000, address(borrower)),   "Cannot drawdown");
        assertTrue(borrower.try_loan_removeCollateral(address(loan), 69_396, address(borrower)), "Cannot remove collateral");

        assertEq(loan.collateral(), 0, "Different collateral");

        // Claim remaining loan proceeds
        assertTrue(lender.try_loan_claimFunds(address(loan), 357_049, address(lender)), "Cannot remove collateral");
    }

    function test_story_interestOnly() external {
        Borrower   borrower = new Borrower();
        LenderMock lender   = new LenderMock();
        MockERC20  token    = new MockERC20("Test", "TST", 0);

        token.mint(address(borrower), 1_000_000);
        token.mint(address(lender),   1_000_000);

        ConstructableMapleLoan loan;
        LoanState memory loanState;

        {
            address[2] memory assets = [address(token), address(token)];

            uint256[6] memory parameters = [
                uint256(10 days),
                uint256(365 days / 6),
                uint256(6),
                uint256(0.12 ether),
                uint256(0.10 ether),
                uint256(0 ether)
            ];

            uint256[3] memory amounts = [uint256(300_000), uint256(1_000_000), uint256(1_000_000)];
            uint256[4] memory fees    = [uint256(0), uint256(0), uint256(0), uint256(0)];

            loan = new ConstructableMapleLoan(address(borrower), assets, parameters, amounts, fees);

            loanState = createDefaultState(address(borrower), parameters, amounts, fees, assets);
        }

        IMapleLoan mockLoan = IMapleLoan(address(loan));

        // Fund via a 500k approval and a 500k transfer, totaling 1M
        lender.erc20_transfer(address(token), address(loan), 500_000);
        lender.erc20_approve(address(token), address(loan),  500_000);

        assertTrue(lender.try_loan_fundLoan(address(loan), address(lender), 500_000), "Cannot lend");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     uint256(0),
                    collateral_:         uint256(0),
                    drawableFunds_:      1_000_000 - getTotalFees(1_000_000, lender, mockLoan),
                    lender_:             address(lender),
                    nextPaymentDueDate_: block.timestamp + mockLoan.paymentInterval(),
                    principal_:          1_000_000,
                    paymentsRemaining_:  mockLoan.paymentsRemaining()
            });
            assert_loan_state(mockLoan, updatedState);
        }

        assertEq(loan.drawableFunds(), 1_000_000, "Different drawable funds");

        borrower.erc20_transfer(address(token), address(loan), 300_000);

        assertTrue(borrower.try_loan_postCollateral(address(loan)),                              "Cannot post");
        assertTrue(borrower.try_loan_drawdownFunds(address(loan), 1_000_000, address(borrower)), "Cannot drawdown");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     uint256(0),
                    collateral_:         300_000,
                    drawableFunds_:      uint256(0),
                    lender_:             address(lender),
                    nextPaymentDueDate_: block.timestamp + mockLoan.paymentInterval(),
                    principal_:          1_000_000,
                    paymentsRemaining_:  mockLoan.paymentsRemaining()
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion, uint256 lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         0,         "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 6,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #1 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #1
        borrower.erc20_transfer(address(token), address(loan), 20_000);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     principalPortion + interestPortion,
                    collateral_:         300_000,
                    drawableFunds_:      uint256(0),
                    lender_:             address(lender),
                    nextPaymentDueDate_: block.timestamp + mockLoan.paymentInterval() + 1,  // that get subtracted above during wrap
                    principal_:          1_000_000,
                    paymentsRemaining_:  5
            });
            assert_loan_state(mockLoan, updatedState);
        }
        
        uint256 currentNextPaymentDueDate = mockLoan.nextPaymentDueDate();

        // Check details for upcoming payment #2
        ( principalPortion, interestPortion, lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         0,         "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 5,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #2 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #2
        borrower.erc20_transfer(address(token), address(loan), 20_000);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     20_000 + principalPortion + interestPortion,
                    collateral_:         300_000,
                    drawableFunds_:      uint256(0),
                    lender_:             address(lender),
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          1_000_000,
                    paymentsRemaining_:  4
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #3
        ( principalPortion, interestPortion, lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         0,         "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 4,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #3 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #3
        borrower.erc20_transfer(address(token), address(loan), 20_000);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     20_000 + 20_000 + principalPortion + interestPortion,
                    collateral_:         300_000,
                    drawableFunds_:      uint256(0),
                    lender_:             address(lender),
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          1_000_000,
                    paymentsRemaining_:  3
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #4
        ( principalPortion, interestPortion, lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         0,         "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 3,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #4 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #4
        borrower.erc20_transfer(address(token), address(loan), 20_000);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        // Return some funds and remove some collateral
        borrower.erc20_transfer(address(token), address(loan), 500_000);

        assertTrue(borrower.try_loan_returnFunds(address(loan)), "Cannot return funds");
        assertTrue(borrower.try_loan_removeCollateral(address(loan), 150_000, address(borrower)), "Cannot remove collateral");

        // Claim loan proceeds thus far
        assertTrue(lender.try_loan_claimFunds(address(loan), 80000, address(lender)), "Cannot claim funds");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     20_000 + 20_000 + 20_000 + principalPortion + interestPortion - 80000,
                    collateral_:         150_000,
                    drawableFunds_:      500_000,
                    lender_:             address(lender),
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          1_000_000,
                    paymentsRemaining_:  2
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #5
        ( principalPortion, interestPortion, lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         0,         "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 2,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #5 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #5
        borrower.erc20_transfer(address(token), address(loan), 20_000);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     principalPortion + interestPortion,
                    collateral_:         150_000,
                    drawableFunds_:      500_000,
                    lender_:             address(lender),
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          1_000_000,
                    paymentsRemaining_:  1
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Check details for upcoming payment #6
        ( principalPortion, interestPortion, lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         1_000_000, "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 1,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #6 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #6
        borrower.erc20_transfer(address(token), address(loan), 1_020_000);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");

        {   
            LoanState memory updatedState = updateLoanState({
                    state_:              loanState,
                    claimableFunds_:     20_000 + principalPortion + interestPortion,
                    collateral_:         150_000,
                    drawableFunds_:      500_000,
                    lender_:             address(lender),
                    nextPaymentDueDate_: currentNextPaymentDueDate = currentNextPaymentDueDate + mockLoan.paymentInterval() * 1,
                    principal_:          0,
                    paymentsRemaining_:  0
            });
            assert_loan_state(mockLoan, updatedState);
        }

        // Remove rest of available funds and collateral
        assertTrue(borrower.try_loan_drawdownFunds(address(loan), 150_000, address(borrower)),    "Cannot drawdown");
        assertTrue(borrower.try_loan_removeCollateral(address(loan), 150_000, address(borrower)), "Cannot remove collateral");

        assertEq(loan.collateral(), 0, "Different collateral");

        // Claim remaining loan proceeds
        assertTrue(lender.try_loan_claimFunds(address(loan), 1_040_000, address(lender)), "Cannot remove collateral");
    }

}
