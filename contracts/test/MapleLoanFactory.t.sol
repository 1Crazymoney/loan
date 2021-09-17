// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { DSTest }               from "../../modules/ds-test/src/test.sol";

import { MapleLoan }            from "../MapleLoan.sol";
import { MapleLoanFactory }     from "../MapleLoanFactory.sol";
import { MapleLoanInitializer } from "../MapleLoanInitializer.sol";

import { Borrower } from "./accounts/Borrower.sol";
import { Governor } from "./accounts/Governor.sol";

contract MapleGlobalsMock {

    address public governor;

    constructor (address governor_) {
        governor = governor_;
    }

}

contract MapleLoanFactoryTest is DSTest {

    Borrower             borrower;
    Borrower             notBorrower;
    Governor             governor;
    Governor             notGovernor;
    MapleGlobalsMock     globals;
    MapleLoanFactory     factory;
    MapleLoan            mapleLoanV1;
    MapleLoan            mapleLoanV2;
    MapleLoanInitializer initializerV1;
    MapleLoanInitializer initializerV2;

    function setUp() external {
        borrower      = new Borrower();
        governor      = new Governor();
        initializerV1 = new MapleLoanInitializer();
        initializerV2 = new MapleLoanInitializer();
        mapleLoanV1   = new MapleLoan();
        mapleLoanV2   = new MapleLoan();
        notBorrower   = new Borrower();
        notGovernor   = new Governor();

        globals = new MapleGlobalsMock(address(governor));
        factory = new MapleLoanFactory(address(globals));
    }

    function test_registerImplementation() external {
        assertTrue(
            !notGovernor.try_mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1)),
            "Should fail to register if not governor"
        );

        assertTrue(
            !governor.try_mapleLoanFactory_registerImplementation(address(factory), 0, address(mapleLoanV1), address(initializerV1)),
            "Should fail to register an invalid version"
        );

        assertTrue(
            !governor.try_mapleLoanFactory_registerImplementation(address(factory), 1, address(0), address(initializerV1)),
            "Should fail to register an invalid implementation address"
        );

        assertTrue(
            governor.try_mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1)),
            "Governor should be able to register"
        );

        assertTrue(
            !governor.try_mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1)),
            "Should fail to register an already registered version"
        );

        assertEq(factory.implementationOf(1),             address(mapleLoanV1),   "Incorrect state of implementationOf");
        assertEq(factory.versionOf(address(mapleLoanV1)), 1,                      "Incorrect state of versionOf");
        assertEq(factory.migratorForPath(1, 1),           address(initializerV1), "Incorrect state of migratorForPath");
    }

    function test_setDefaultVersion() external {
        governor.mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1));

        assertTrue(
            !notGovernor.try_mapleLoanFactory_setDefaultVersion(address(factory), 1),
            "Should fail to set default version if not governor"
        );

        assertTrue(
            !governor.try_mapleLoanFactory_setDefaultVersion(address(factory), 2),
            "Should fail to set default version if not registered"
        );

        assertTrue(
            governor.try_mapleLoanFactory_setDefaultVersion(address(factory), 1),
            "Should be able to set default version"
        );

        assertEq(factory.defaultVersion(), 1, "Incorrect state of defaultVersion");

        assertTrue(
            !notGovernor.try_mapleLoanFactory_setDefaultVersion(address(factory), 0),
            "Should fail to unset default version if not governor"
        );

        assertTrue(
            governor.try_mapleLoanFactory_setDefaultVersion(address(factory), 0),
            "Should be able to unset default version"
        );

        assertEq(factory.defaultVersion(), 0, "Incorrect state of defaultVersion");
    }

    function test_createLoan() external {
        address[2] memory assets = [address(4567), address(9876)];

        uint256[6] memory parameters = [
            uint256(0),
            uint256(10 days),
            uint256(120_000),
            uint256(100_000),
            uint256(365 days / 6),
            uint256(6)
        ];

        uint256[2] memory requests = [uint256(300_000), uint256(1_000_000)];

        bytes memory arguments = initializerV1.encodeArguments(address(borrower), assets, parameters, requests);

        assertTrue(
            !borrower.try_mapleLoanFactory_createLoan(address(factory), arguments),
            "Should fail to create loan for an unregistered version"
        );

        governor.mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1));
        governor.mapleLoanFactory_setDefaultVersion(address(factory), 1);

        assertTrue(
            !borrower.try_mapleLoanFactory_createLoan(address(factory), new bytes(0)),
            "Should fail to create loan with invalid arguments"
        );

        assertTrue(borrower.try_mapleLoanFactory_createLoan(address(factory), arguments), "Should not fail to create a loan");

        assertEq(factory.loanCount(), 1);

        assertTrue(borrower.try_mapleLoanFactory_createLoan(address(factory), arguments), "Should not fail to create a loan");

        assertEq(factory.loanCount(), 2);

        assertTrue(factory.loanAtIndex(0) != factory.loanAtIndex(1), "Loans should have unique addresses");

        MapleLoan loan = MapleLoan(factory.loanAtIndex(0));

        assertEq(loan.factory(),                           address(factory));
        assertEq(loan.implementation(),                    address(mapleLoanV1));
        assertEq(factory.versionOf(loan.implementation()), 1);
    }

    function test_enableUpgradePath() external {
        governor.mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1));
        governor.mapleLoanFactory_registerImplementation(address(factory), 2, address(mapleLoanV2), address(initializerV2));

        assertTrue(
            !governor.try_mapleLoanFactory_enableUpgradePath(address(factory), 1, 1, address(444444)),
            "Should fail to overwrite initializer"
        );

        assertTrue(
            !governor.try_mapleLoanFactory_enableUpgradePath(address(factory), 2, 1, address(444444)),
            "Should fail to enable a downgrade"
        );

        assertTrue(
            !notGovernor.try_mapleLoanFactory_enableUpgradePath(address(factory), 1, 2, address(444444)),
            "Should fail to enable an upgrade if not governor"
        );

        assertTrue(
            governor.try_mapleLoanFactory_enableUpgradePath(address(factory), 1, 2, address(444444)),
            "Should be able to enable an upgrade path"
        );

        assertEq(factory.migratorForPath(1, 2), address(444444), "Incorrect migrator");

        assertTrue(
            governor.try_mapleLoanFactory_enableUpgradePath(address(factory), 1, 2, address(888888)),
            "Should be able to enable an upgrade path and change the migrator"
        );

        assertEq(factory.migratorForPath(1, 2), address(888888), "Incorrect migrator");
    }

    function test_disableUpgradePath() external {
        governor.mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1));
        governor.mapleLoanFactory_registerImplementation(address(factory), 2, address(mapleLoanV2), address(initializerV2));
        governor.mapleLoanFactory_enableUpgradePath(address(factory), 1, 2, address(444444));

        assertEq(factory.migratorForPath(1, 2), address(444444), "Incorrect migrator");

        assertTrue(
            !notGovernor.try_mapleLoanFactory_disableUpgradePath(address(factory), 1, 2),
            "Should fail to disable upgrade path if not governor"
        );

        assertTrue(
            governor.try_mapleLoanFactory_disableUpgradePath(address(factory), 1, 2),
            "Should be able to disable upgrade path"
        );

        assertTrue(
            !governor.try_mapleLoanFactory_disableUpgradePath(address(factory), 1, 1),
            "Should fail to overwrite initializer"
        );

        assertEq(factory.migratorForPath(1, 2), address(0), "Incorrect migrator");
    }

    function test_upgradeLoan() external {
        governor.mapleLoanFactory_registerImplementation(address(factory), 1, address(mapleLoanV1), address(initializerV1));
        governor.mapleLoanFactory_registerImplementation(address(factory), 2, address(mapleLoanV2), address(initializerV2));
        governor.mapleLoanFactory_setDefaultVersion(address(factory), 1);

        address[2] memory assets = [address(4567), address(9876)];

        uint256[6] memory parameters = [
            uint256(0),
            uint256(10 days),
            uint256(120_000),
            uint256(100_000),
            uint256(365 days / 6),
            uint256(6)
        ];

        uint256[2] memory requests = [uint256(300_000), uint256(1_000_000)];

        bytes memory arguments = initializerV1.encodeArguments(address(borrower), assets, parameters, requests);

        MapleLoan loan = MapleLoan(borrower.mapleLoanFactory_createLoan(address(factory), arguments));

        assertEq(loan.implementation(),                    address(mapleLoanV1));
        assertEq(factory.versionOf(loan.implementation()), 1);

        assertTrue(!borrower.try_loan_upgrade(address(loan), 2, new bytes(0)), "Should not be able to upgrade loan if upgrade path not enabled");

        governor.mapleLoanFactory_enableUpgradePath(address(factory), 1, 2, address(0));

        assertTrue(!notBorrower.try_loan_upgrade(address(loan), 2, new bytes(0)), "Should not be able to upgrade loan if not borrower");
        assertTrue(   !borrower.try_loan_upgrade(address(loan), 0, new bytes(0)), "Should not be able to upgrade loan to invalid version");
        assertTrue(   !borrower.try_loan_upgrade(address(loan), 1, new bytes(0)), "Should not be able to upgrade loan to same version");
        assertTrue(   !borrower.try_loan_upgrade(address(loan), 3, new bytes(0)), "Should not be able to upgrade loan to non-existent version");
        assertTrue(    borrower.try_loan_upgrade(address(loan), 2, new bytes(0)), "Should be able to upgrade loan");

        assertEq(loan.implementation(),                    address(mapleLoanV2));
        assertEq(factory.versionOf(loan.implementation()), 2);
    }

}
