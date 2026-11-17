// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, console } from "forge-std/Test.sol";
import { DripVault } from "../src/DripVault.sol";
import { DripReactive } from "../src/DripReactive.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MockSystem, MockProxy } from "./Mocks.sol";

/// @notice Full test suite for DripPay (Reactive Omni Buildathon).
///         Covers the vault, the reactive contract, and the end-to-end loop
///         (origin event -> reactive -> callback -> release) with mocks.
contract DripPayTest is Test {
    // ---- Shared constants ----
    address payable constant SYSTEM_ADDR = payable(0x8888888888888888888888888888888888888888);
    address constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant CRON100_TOPIC_0 =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 constant SCHEDULE_CREATED_TOPIC_0 =
        0xcc0d6e1355c255fcd002259c1b6ed991322161e4f554f7b98bb1547644db73be;
    uint256 constant SCHEDULE_CANCELLED_TOPIC_0 =
        0xaafc09ed0175af188e56c12f5eda79a11a6d2d747621fb47b25f301d499fdc5e;
    uint256 constant PAYMENT_RELEASED_TOPIC_0 =
        0xe120094e1b9eaf4ca9d812ae01a7158f9e3c3357b5d63a15a2b7953394243e73;

    uint256 constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 constant LASNA_CHAIN = 5318007;

    address owner = address(0xA11CE);
    address recipient = address(0xBEEF);
    address reactiveAddr = address(0xCA11BAC);

    MockProxy proxy;
    DripVault vault;

    function setUp() public {
        vm.deal(owner, 100 ether);
        vm.deal(recipient, 1 ether);
        proxy = new MockProxy();
        vm.deal(address(proxy), 10 ether);
        vault = new DripVault(proxy, reactiveAddr);
        vm.deal(address(vault), 10 ether);
    }

    // ============ DripVault ============

    function testCreateScheduleEscrowsAndEmits() public {
        vm.startPrank(owner);
        uint256 amount = 0.01 ether;
        uint256 payments = 4;
        uint256 interval = 300;
        vm.expectEmit(true, true, false, true, address(vault));
        emit DripVault.ScheduleCreated(
            0, owner, recipient, amount, interval, payments, block.timestamp + interval
        );
        uint256 id = vault.createSchedule{ value: amount * payments + 0.002 ether }(
            recipient, amount, interval, payments
        );
        vm.stopPrank();

        assertEq(id, 0);
        DripVault.Schedule memory s = vault.getSchedule(0);
        assertEq(s.owner, owner);
        assertEq(s.recipient, recipient);
        assertEq(s.amount, amount);
        assertEq(s.intervalSeconds, interval);
        assertEq(s.paymentsLeft, payments);
        assertEq(s.escrow, amount * payments);
        assertTrue(s.active);
        assertEq(s.nextDue, block.timestamp + interval);
    }

    function testCreateScheduleRevertsOnShortDeposit() public {
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(DripVault.InsufficientDeposit.selector, 0.042 ether, 0.01 ether)
        );
        vault.createSchedule{ value: 0.01 ether }(recipient, 0.01 ether, 300, 4);
        vm.stopPrank();
    }

    function testCreateScheduleRevertsOnBadParams() public {
        vm.startPrank(owner);
        vm.expectRevert(DripVault.InvalidRecipient.selector);
        vault.createSchedule{ value: 1 ether }(address(0), 0.01 ether, 300, 4);
        vm.expectRevert(DripVault.InvalidAmount.selector);
        vault.createSchedule{ value: 1 ether }(recipient, 0, 300, 4);
        vm.expectRevert(DripVault.InvalidInterval.selector);
        vault.createSchedule{ value: 1 ether }(recipient, 0.01 ether, 59, 4);
        vm.expectRevert(DripVault.InvalidPayments.selector);
        vault.createSchedule{ value: 1 ether }(recipient, 0.01 ether, 300, 0);
        vm.stopPrank();
    }

    function testCancelRefundsEscrow() public {
        vm.startPrank(owner);
        uint256 id = vault.createSchedule{ value: 0.042 ether }(recipient, 0.01 ether, 300, 4);
        uint256 before = owner.balance;
        vault.cancelSchedule(id);
        vm.stopPrank();
        assertEq(owner.balance, before + 0.04 ether);
        assertFalse(vault.getSchedule(id).active);
    }

    function testCancelRevertsForNonOwner() public {
        vm.startPrank(owner);
        uint256 id = vault.createSchedule{ value: 0.042 ether }(recipient, 0.01 ether, 300, 4);
        vm.stopPrank();
        vm.expectRevert(DripVault.NotScheduleOwner.selector);
        vault.cancelSchedule(id);
    }

    function testTopUpAddsPayments() public {
        vm.startPrank(owner);
        uint256 id = vault.createSchedule{ value: 0.042 ether }(recipient, 0.01 ether, 300, 4);
        vault.topUpSchedule{ value: 0.02 ether }(id, 2);
        vm.stopPrank();
        DripVault.Schedule memory s = vault.getSchedule(id);
        assertEq(s.paymentsLeft, 6);
        assertEq(s.escrow, 0.06 ether);
    }

    function _fundedSchedule() internal returns (uint256 id) {
        vm.startPrank(owner);
        id = vault.createSchedule{ value: 0.042 ether }(recipient, 0.01 ether, 300, 4);
        vm.stopPrank();
    }

    function testReleasePaysRecipientAndAdvances() public {
        uint256 id = _fundedSchedule();
        vm.warp(block.timestamp + 300);
        uint256 before = recipient.balance;
        vm.prank(address(proxy));
        vault.release(reactiveAddr, id);
        assertEq(recipient.balance, before + 0.01 ether);
        DripVault.Schedule memory s = vault.getSchedule(id);
        assertEq(s.paymentsLeft, 3);
        assertEq(s.escrow, 0.03 ether);
        assertEq(s.nextDue, block.timestamp + 300);
        assertTrue(s.active);
    }

    function testReleaseDeactivatesAfterLastPayment() public {
        uint256 id = _fundedSchedule();
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 300);
            vm.prank(address(proxy));
            vault.release(reactiveAddr, id);
        }
        DripVault.Schedule memory s = vault.getSchedule(id);
        assertEq(s.paymentsLeft, 0);
        assertEq(s.escrow, 0);
        assertFalse(s.active);
    }

    function testReleaseRevertsBeforeDue() public {
        uint256 id = _fundedSchedule();
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(
                DripVault.PaymentNotDue.selector, block.timestamp + 300, block.timestamp
            )
        );
        vault.release(reactiveAddr, id);
    }

    function testReleaseRevertsForWrongSender() public {
        uint256 id = _fundedSchedule();
        vm.warp(block.timestamp + 300);
        // Wrong reactive address.
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("CallbackNotAuthorized(address,address)")),
                address(0xDEAD),
                reactiveAddr
            )
        );
        vault.release(address(0xDEAD), id);
        // Wrong caller (not the proxy).
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("NotAuthorized(address,address)")),
                address(this),
                address(proxy)
            )
        );
        vault.release(reactiveAddr, id);
    }

    function testVaultPaysCallbackFees() public {
        // The proxy bills the vault via pay(); it must succeed from reserves.
        uint256 before = address(vault).balance;
        vm.prank(address(proxy));
        vault.pay(0.001 ether);
        assertEq(address(vault).balance, before - 0.001 ether);
    }

    // ============ DripReactive ============

    MockSystem sys;
    DripReactive reactive;
    address vaultAddr = address(0x1111111111111111111111111111111111111111);

    function _deployReactive() internal {
        sys = new MockSystem();
        // Etch the mock system contract at the real system address.
        vm.etch(SYSTEM_ADDR, address(sys).code);
        vm.deal(SYSTEM_ADDR, 10 ether);
        vm.deal(address(this), 100 ether);
        reactive = new DripReactive{ value: 1 ether }(ORIGIN_CHAIN, vaultAddr, ORIGIN_CHAIN);
    }

    function _mockSystem() internal pure returns (MockSystem) {
        return MockSystem(SYSTEM_ADDR);
    }

    function _scheduleCreatedLog(uint256 scheduleId, uint256 nextDue)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: vaultAddr,
            topic0: SCHEDULE_CREATED_TOPIC_0,
            topic1: scheduleId,
            topic2: uint256(uint160(owner)),
            topic3: 0,
            data: abi.encode(recipient, 0.01 ether, uint256(300), uint256(4), nextDue),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: LASNA_CHAIN,
            contractAddress: LEGACY_SYSTEM_ADDR,
            topic0: CRON100_TOPIC_0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(block.number),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function testReactiveSubscribesOnDeploy() public {
        _deployReactive();
        // 3 vault subscriptions + 1 CRON subscription.
        assertEq(_mockSystem().subscriptionCount(), 4);
    }

    function testReactiveRejectsNonSystemCaller() public {
        _deployReactive();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("NotAuthorized(address,address)")),
                address(this),
                SYSTEM_ADDR
            )
        );
        reactive.react(_cronLog());
    }

    function testMirrorScheduleOnCreatedEvent() public {
        _deployReactive();
        uint256 nextDue = block.timestamp + 300;
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scheduleCreatedLog(7, nextDue));
        DripReactive.Mirror memory m = reactive.getMirror(7);
        assertTrue(m.active);
        assertEq(m.recipient, recipient);
        assertEq(m.amount, 0.01 ether);
        assertEq(m.intervalSeconds, 300);
        assertEq(m.paymentsLeft, 4);
        assertEq(m.nextDue, nextDue);
    }

    function testCronRequestsCallbackOnlyWhenDue() public {
        _deployReactive();
        uint256 nextDue = block.timestamp + 300;
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scheduleCreatedLog(7, nextDue));

        // Tick before due: no callback.
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 0);

        // Tick after due: exactly one callback, to the vault on Base Sepolia.
        vm.warp(block.timestamp + 301);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 1);
        MockSystem.CallbackConfiguration_V_1_0 memory cb = _mockSystem().getCallback(0);
        assertEq(cb.chainId, ORIGIN_CHAIN);
        assertEq(cb.recipient, vaultAddr);
        assertEq(cb.gasLimit, 500000);
        // Payload must be exactly release(address(0), 7).
        assertEq(
            keccak256(cb.payload),
            keccak256(abi.encodeWithSignature("release(address,uint256)", address(0), uint256(7)))
        );
    }

    function testPendingGuardPreventsDuplicates() public {
        _deployReactive();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scheduleCreatedLog(7, block.timestamp + 300));
        vm.warp(block.timestamp + 301);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 1);
        // Second tick 1 minute later: still pending, no duplicate.
        vm.warp(block.timestamp + 60);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 1);
        // After the 10-minute pending timeout: retried.
        vm.warp(block.timestamp + 601);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 2);
    }

    function testPaymentReleasedUpdatesMirror() public {
        _deployReactive();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scheduleCreatedLog(7, block.timestamp + 300));
        vm.warp(block.timestamp + 301);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 1);

        // PaymentReleased event clears pending and advances the mirror.
        uint256 newDue = block.timestamp + 600;
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: vaultAddr,
            topic0: PAYMENT_RELEASED_TOPIC_0,
            topic1: 7,
            topic2: 0,
            topic3: 0,
            data: abi.encode(recipient, 0.01 ether, uint256(3), newDue),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        DripReactive.Mirror memory m = reactive.getMirror(7);
        assertEq(m.paymentsLeft, 3);
        assertEq(m.nextDue, newDue);
        assertTrue(m.active);

        // Next tick before the new due: no callback.
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 1);
    }

    function testCancelUnmirrorsSchedule() public {
        _deployReactive();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scheduleCreatedLog(7, block.timestamp + 300));
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: vaultAddr,
            topic0: SCHEDULE_CANCELLED_TOPIC_0,
            topic1: 7,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertFalse(reactive.getMirror(7).active);
        vm.warp(block.timestamp + 301);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 0);
    }

    function testPauseStopsCronReleases() public {
        _deployReactive();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scheduleCreatedLog(7, block.timestamp + 300));
        reactive.pause();
        vm.warp(block.timestamp + 301);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 0);
        reactive.resume();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_cronLog());
        assertEq(_mockSystem().callbackCount(), 1);
    }

    // ============ End-to-end loop ============

    function testEndToEndLoop() public {
        // Real vault + reactive wired together with mocks for system/proxy.
        sys = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(sys).code);
        vm.deal(SYSTEM_ADDR, 10 ether);

        DripVault realVault = new DripVault(proxy, address(0)); // sender set after reactive deploys
        // NOTE: _CALLBACK_SENDER is immutable, so deploy in the documented order:
        // reactive first, then vault with the reactive address.
        DripReactive realReactive = new DripReactive{ value: 1 ether }(
            ORIGIN_CHAIN, address(realVault), ORIGIN_CHAIN
        );
        // Redeploy the vault with the real reactive address (fresh vault).
        realVault = new DripVault(proxy, address(realReactive));
        vm.deal(address(realVault), 10 ether);
        // Point the reactive contract at the final vault.
        realReactive.setVault(address(realVault));

        // 1. User creates a schedule on the vault.
        vm.startPrank(owner);
        uint256 id = realVault.createSchedule{ value: 0.042 ether }(
            recipient, 0.01 ether, 300, 4
        );
        vm.stopPrank();
        uint256 nextDue = block.timestamp + 300;

        // 2. The ScheduleCreated event reaches the reactive contract.
        IReactive.LogRecord memory created = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(realVault),
            topic0: SCHEDULE_CREATED_TOPIC_0,
            topic1: id,
            topic2: uint256(uint160(owner)),
            topic3: 0,
            data: abi.encode(recipient, 0.01 ether, uint256(300), uint256(4), nextDue),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        realReactive.react(created);
        assertTrue(realReactive.getMirror(id).active);

        // 3. A CRON tick after the due time triggers a callback request.
        vm.warp(block.timestamp + 301);
        vm.prank(SYSTEM_ADDR);
        realReactive.react(_cronLogFor(address(realReactive)));
        assertEq(_mockSystem().callbackCount(), 1);
        MockSystem.CallbackConfiguration_V_1_0 memory cb = _mockSystem().getCallback(0);
        assertEq(cb.recipient, address(realVault));

        // 4. The network delivers the callback: the proxy calls release().
        uint256 before = recipient.balance;
        vm.prank(address(proxy));
        realVault.release(address(realReactive), id);
        assertEq(recipient.balance, before + 0.01 ether);

        // 5. The PaymentReleased event updates the reactive mirror.
        DripVault.Schedule memory s = realVault.getSchedule(id);
        IReactive.LogRecord memory released = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(realVault),
            topic0: PAYMENT_RELEASED_TOPIC_0,
            topic1: id,
            topic2: 0,
            topic3: 0,
            data: abi.encode(recipient, 0.01 ether, s.paymentsLeft, s.nextDue),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        realReactive.react(released);
        DripReactive.Mirror memory m = realReactive.getMirror(id);
        assertEq(m.paymentsLeft, 3);
        assertEq(m.nextDue, s.nextDue);
        assertTrue(m.active);
        console.log("End-to-end loop OK: event -> react -> callback -> release -> mirror update");
    }

    function _cronLogFor(address) internal view returns (IReactive.LogRecord memory) {
        return _cronLog();
    }
}
