// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title DripPay Reactive — the automation brain on Reactive Lasna.
/// @notice Mirrors payment schedules from the DripVault (origin chain) by
///         subscribing to its events, then releases due payments on every
///         CRON tick by requesting callbacks back to the vault. No bot, no
///         keeper, no server: the schedule runs itself.
/// @dev Built for the Reactive Omni Buildathon (Set It and Forget It track).
///      Demo topology: vault on Base Sepolia (84532), reactive on Lasna
///      (5318007), callbacks back to Base Sepolia. The same code runs
///      single-chain on Lasna (origin == destination == Lasna).
contract DripReactive is AbstractReactive {
    /// @notice Legacy system contract that emits Cron events.
    address internal constant LEGACY_SYSTEM_ADDR =
        0x0000000000000000000000000000000000fffFfF;

    /// @notice Cron100 fires every 100 Lasna blocks (~2 minutes).
    uint256 internal constant CRON100_TOPIC_0 =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    /// @notice keccak256("ScheduleCreated(uint256,address,address,uint256,uint256,uint256,uint256)")
    uint256 internal constant SCHEDULE_CREATED_TOPIC_0 =
        0xcc0d6e1355c255fcd002259c1b6ed991322161e4f554f7b98bb1547644db73be;
    /// @notice keccak256("ScheduleCancelled(uint256)")
    uint256 internal constant SCHEDULE_CANCELLED_TOPIC_0 =
        0xaafc09ed0175af188e56c12f5eda79a11a6d2d747621fb47b25f301d499fdc5e;
    /// @notice keccak256("PaymentReleased(uint256,address,uint256,uint256,uint256)")
    uint256 internal constant PAYMENT_RELEASED_TOPIC_0 =
        0xe120094e1b9eaf4ca9d812ae01a7158f9e3c3357b5d63a15a2b7953394243e73;

    /// @notice Gas limit requested for each release callback.
    uint64 internal constant CALLBACK_GAS_LIMIT = 500000;

    /// @notice A pending callback older than this is retried on the next tick.
    uint256 internal constant PENDING_TIMEOUT = 600;

    /// @notice Max mirrored schedules (bounds the CRON scan gas).
    uint256 internal constant MAX_ACTIVE = 50;

    address public owner;
    uint256 public originChainId;
    address public vault;
    uint256 public destinationChainId;
    bool public paused;

    struct Mirror {
        address recipient;
        uint256 amount;
        uint256 intervalSeconds;
        uint256 paymentsLeft;
        uint256 nextDue;
        bool active;
    }

    mapping(uint256 => Mirror) public mirrors;
    uint256[] public activeIds;
    mapping(uint256 => uint256) public pendingSince;

    event ScheduleMirrored(uint256 indexed scheduleId, uint256 nextDue);
    event ScheduleUnmirrored(uint256 indexed scheduleId);
    event PaymentRequested(uint256 indexed scheduleId, uint256 nextDue);
    event PaymentConfirmed(uint256 indexed scheduleId, uint256 paymentsLeft, uint256 nextDue);
    event MirrorFull(uint256 indexed scheduleId);
    event DestinationSet(uint256 chainId, address vault);
    event Paused(bool paused);

    error OnlyOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @param originChainId_ Chain the vault lives on (84532 Base Sepolia in the demo).
    /// @param vault_ DripVault address on the origin chain.
    /// @param destinationChainId_ Chain callbacks are delivered to (same as origin in the demo).
    constructor(uint256 originChainId_, address vault_, uint256 destinationChainId_) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        vault = vault_;
        destinationChainId = destinationChainId_;
        _subscribeVault();
        _subscribeCron();
    }

    // ---- Subscriptions ----

    function _subscribeVault() internal {
        SYSTEM.subscribe(originChainId, vault, SCHEDULE_CREATED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId, vault, SCHEDULE_CANCELLED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId, vault, PAYMENT_RELEASED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _unsubscribeVault() internal {
        SYSTEM.unsubscribe(originChainId, vault, SCHEDULE_CREATED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(originChainId, vault, SCHEDULE_CANCELLED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(originChainId, vault, PAYMENT_RELEASED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _subscribeCron() internal {
        SYSTEM.subscribe(block.chainid, LEGACY_SYSTEM_ADDR, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _unsubscribeCron() internal {
        SYSTEM.unsubscribe(block.chainid, LEGACY_SYSTEM_ADDR, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    // ---- Owner controls ----

    /// @notice Point the reactive contract at a (re)deployed vault.
    function setVault(address vault_) external onlyOwner {
        _unsubscribeVault();
        vault = vault_;
        _subscribeVault();
        emit DestinationSet(destinationChainId, vault_);
    }

    /// @notice Change the callback destination chain.
    function setDestinationChain(uint256 destinationChainId_) external onlyOwner {
        destinationChainId = destinationChainId_;
        emit DestinationSet(destinationChainId_, vault);
    }

    /// @notice Pause CRON-driven releases (event mirroring stays live).
    function pause() external onlyOwner {
        if (!paused) {
            paused = true;
            _unsubscribeCron();
            emit Paused(true);
        }
    }

    /// @notice Resume CRON-driven releases.
    function resume() external onlyOwner {
        if (paused) {
            paused = false;
            _coverDebt();
            _subscribeCron();
            emit Paused(false);
        }
    }

    /// @notice Settle outstanding debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    // ---- Reactive entry point ----

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        if (log_.topic0 == SCHEDULE_CREATED_TOPIC_0) {
            _onScheduleCreated(log_);
        } else if (log_.topic0 == SCHEDULE_CANCELLED_TOPIC_0) {
            _onScheduleCancelled(log_);
        } else if (log_.topic0 == PAYMENT_RELEASED_TOPIC_0) {
            _onPaymentReleased(log_);
        } else if (log_.topic0 == CRON100_TOPIC_0) {
            _onCronTick();
        }
        // Unknown topics fall through silently (never revert as a filter).
    }

    function _onScheduleCreated(LogRecord memory log_) internal {
        // LOG3: topic1 = scheduleId, topic2 = owner.
        // data = (recipient, amount, intervalSeconds, payments, nextDue).
        if (log_.opCode != 3) return;
        uint256 scheduleId = log_.topic1;
        if (mirrors[scheduleId].active) return; // already mirrored
        if (activeIds.length >= MAX_ACTIVE) {
            emit MirrorFull(scheduleId);
            return;
        }
        (address recipient, uint256 amount, uint256 intervalSeconds, uint256 payments, uint256 nextDue) =
            abi.decode(log_.data, (address, uint256, uint256, uint256, uint256));
        mirrors[scheduleId] = Mirror({
            recipient: recipient,
            amount: amount,
            intervalSeconds: intervalSeconds,
            paymentsLeft: payments,
            nextDue: nextDue,
            active: true
        });
        activeIds.push(scheduleId);
        emit ScheduleMirrored(scheduleId, nextDue);
    }

    function _onScheduleCancelled(LogRecord memory log_) internal {
        // LOG2: topic1 = scheduleId.
        if (log_.opCode != 2) return;
        uint256 scheduleId = log_.topic1;
        mirrors[scheduleId].active = false;
        delete pendingSince[scheduleId];
        emit ScheduleUnmirrored(scheduleId);
    }

    function _onPaymentReleased(LogRecord memory log_) internal {
        // LOG2: topic1 = scheduleId.
        // data = (recipient, amount, paymentsLeft, nextDue).
        if (log_.opCode != 2) return;
        uint256 scheduleId = log_.topic1;
        (, , uint256 paymentsLeft, uint256 nextDue) =
            abi.decode(log_.data, (address, uint256, uint256, uint256));
        Mirror storage m = mirrors[scheduleId];
        m.paymentsLeft = paymentsLeft;
        m.nextDue = nextDue;
        if (paymentsLeft == 0) m.active = false;
        delete pendingSince[scheduleId];
        emit PaymentConfirmed(scheduleId, paymentsLeft, nextDue);
    }

    function _onCronTick() internal {
        if (paused) return;
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < activeIds.length; i++) {
            uint256 id = activeIds[i];
            Mirror storage m = mirrors[id];
            if (!m.active || m.paymentsLeft == 0) continue;
            if (m.nextDue > now_) continue;
            uint256 pending = pendingSince[id];
            if (pending != 0 && now_ - pending < PENDING_TIMEOUT) continue;
            pendingSince[id] = now_;
            _requestRelease(id);
        }
    }

    function _requestRelease(uint256 scheduleId_) internal {
        uint256 nextDue = mirrors[scheduleId_].nextDue;
        bytes memory payload = abi.encodeWithSignature(
            "release(address,uint256)", address(0), scheduleId_
        );
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: destinationChainId,
            recipient: vault,
            gasLimit: CALLBACK_GAS_LIMIT,
            payload: payload
        }));
        emit PaymentRequested(scheduleId_, nextDue);
    }

    // ---- Views ----

    /// @notice Mirror record for a schedule id.
    function getMirror(uint256 scheduleId_) external view returns (Mirror memory) {
        return mirrors[scheduleId_];
    }

    /// @notice All currently mirrored active schedule ids.
    function getActiveIds() external view returns (uint256[] memory) {
        return activeIds;
    }
}
