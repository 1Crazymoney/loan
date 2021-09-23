// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { DSTest }    from "../../modules/ds-test/src/test.sol";
import { IERC20 }    from "../../modules/erc20/src/interfaces/IERC20.sol";
import { MockERC20 } from "../../modules/erc20/src/test/mocks/MockERC20.sol";

import { Borrower } from "./accounts/Borrower.sol";
import { Lender }   from "./accounts/Lender.sol";

import { MapleLoan } from "./../MapleLoan.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract ConstructableMapleLoan is MapleLoan {

    constructor(address borrower_, address[2] memory assets_, uint256[6] memory parameters_, uint256[2] memory amounts_) {
        _initialize(borrower_, assets_, parameters_, amounts_);
    }

}

contract RefinanceTest is DSTest {

    Hevm hevm;

    MockERC20              token;   
    Borrower               borrower;
    Lender                 lender;
    ConstructableMapleLoan loan;

    constructor() {
        hevm = Hevm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
    }

    // This function initializes and makes a payment
    function setUpOngoinLoan() internal {

        token    = new MockERC20("Test", "TST", 0);
        borrower = new Borrower();
        lender   = new Lender();

        token.mint(address(borrower), 1_000_000);
        token.mint(address(lender),   1_000_000);

        address[2] memory assets = [address(token), address(token)];

        uint256[6] memory parameters = [
            uint256(0),
            uint256(10 days),
            uint256(120_000),
            uint256(100_000),
            uint256(365 days / 6),
            uint256(6)
        ];

        uint256[2] memory requests = [uint256(300_000), uint256(1_000_000)];

        loan = new ConstructableMapleLoan(address(borrower), assets, parameters, requests);

        lender.erc20_transfer(address(token), address(loan), 1_000_000);

        assertTrue(lender.try_loan_lend(address(loan), address(lender)), "Cannot lend");

        assertEq(loan.drawableFunds(), 1_000_000, "Different drawable funds");

        borrower.erc20_transfer(address(token), address(loan), 300_000);

        assertTrue(borrower.try_loan_postCollateral(address(loan)),                              "Cannot post");
        assertTrue(borrower.try_loan_drawdownFunds(address(loan), 1_000_000, address(borrower)), "Cannot drawdown");

        assertEq(loan.drawableFunds(), 0, "Different drawable funds");

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion, uint256 lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         158_526,   "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 6,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #1 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #1
        borrower.erc20_transfer(address(token), address(loan), 178_526);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");
    }

    function test_refinance_story_extendTerm() external {
        setUpOngoinLoan();

        address[2] memory newAssets = [loan.fundsAsset(), loan.collateralAsset()];
 
        uint256[13] memory newTerms = [
            loan.endingPrincipal(),  
            loan.gracePeriod(),      
            loan.interestRate(),     
            loan.lateFeeRate(),      
            loan.paymentInterval(),  
            loan.collateralRequired(),  
            loan.principalRequested(),  
            loan.drawableFunds(),       
            loan.claimableFunds(),      
            loan.collateral(),          
            loan.nextPaymentDueDate(),  
            loan.paymentsRemaining() + 24, // Extending for 24 more payment cycles    
            loan.principal()             
        ];

        uint256 totalPayments =  loan.paymentsRemaining() + 24;

        borrower.loan_proposeNewTerms(address(loan), newAssets, newTerms);

        assertTrue(loan.newTermsHash() != bytes32(""));

        lender.loan_acceptNewTerms(address(loan), newAssets, newTerms); //Loan was effectively refinanced
    
        assertEq(loan.paymentsRemaining(), totalPayments);

    }

    function test_refinance_story_increasePrincipalAndCollateral() external {
        setUpOngoinLoan();

        uint256 extraPrincipal  = loan.principal() + 1_000_000 * 10**18;
        uint256 extraCollateral = loan.collateral() + 300_000 * 1**18;

        address[2] memory newAssets = [loan.fundsAsset(), loan.collateralAsset()];
 
        uint256[13] memory newTerms = [
            loan.endingPrincipal(),  
            loan.gracePeriod(),      
            loan.interestRate(),     
            loan.lateFeeRate(),      
            loan.paymentInterval(),  
            loan.collateralRequired() + extraCollateral,  
            loan.principalRequested() + extraPrincipal,  
            loan.drawableFunds() + extraPrincipal,        
            loan.claimableFunds(),      
            loan.collateral() + extraCollateral,          
            loan.nextPaymentDueDate(),  
            loan.paymentsRemaining() + 24, // Extending for 24 more payment cycles    
            loan.principal() + extraPrincipal          
        ];

        borrower.loan_proposeNewTerms(address(loan), newAssets, newTerms);

        assertTrue(loan.newTermsHash() != bytes32(""));

        token.mint(address(loan), extraCollateral);
        borrower.loan_postCollateral(address(loan));

        token.mint(address(loan), extraPrincipal);
        lender.loan_acceptNewTerms(address(loan), newAssets, newTerms);
    }

    
}