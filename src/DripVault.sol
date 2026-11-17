// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title DripPay Vault — destination-chain contract for recurring payments.
/// @notice Holds escrowed funds for payment schedules. Only the authorised
///         reactive contract (via the Reactive callback proxy) can release a
///         payment. Users create/cancel schedules and fund the escrow.
/// @dev Built for the Reactive Omni Buildathon (Set It and Forget It track).
///      Destination chain in the demo: Base Sepolia (84532). The same code
///      deploys on Lasna (5318007) for the single-chain topology.
contract DripVault is AbstractCallback {
    /// @notice Reserve held per schedule to cover callback gas charged by the proxy.
    uint256 public constant GAS_RESERVE = 0.002 ether;

    /// @notice Minimum interval between payments (1 minute — demo friendly).
    uint256 public constant MIN_INTERVAL = 60;

    struct Schedule {
        address owner;
        address recipient;
        uint256 amount;
        uint256 intervalSeconds;
        uint256 paymentsLeft;
        uint256 nextDue;
        uint256 escrow;
        bool active;
    }

    uint256 public nextScheduleId;
    mapping(uint256 => Schedule) public schedules;

    /// @notice Emitted when a schedule is created (the reactive contract mirrors from this).
    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed owner,
        address recipient,
        uint256 amount,
        uint256 intervalSeconds,
        uint256 payments,
        uint256 nextDue
    );
    /// @notice Emitted when extra payments are funded into a schedule.
    event ScheduleFunded(uint256 indexed scheduleId, uint256 extraPayments, uint256 newEscrow);
    /// @notice Emitted when a schedule is cancelled (the reactive contract mirrors from this).
    event ScheduleCancelled(uint256 indexed scheduleId);
    /// @notice Emitted when a payment is released (the reactive contract mirrors from this).
    event PaymentReleased(
        uint256 indexed scheduleId,
        address recipient,
        uint256 amount,
        uint256 paymentsLeft,
        uint256 nextDue
    );

    error InvalidRecipient();
    error InvalidAmount();
    error InvalidInterval();
    error InvalidPayments();
    error InsufficientDeposit(uint256 required, uint256 provided);
    error NotScheduleOwner();
    error ScheduleNotActive();
    error PaymentNotDue(uint256 nextDue, uint256 now_);
    error InsufficientEscrow();

    /// @param callbackProxy_ Callback proxy of the destination chain.
    /// @param callbackSender_ Reactive contract authorised to trigger releases.
    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {}

    /// @notice Create a recurring payment schedule, escrowing the full amount.
    /// @param recipient_ Who receives each payment.
    /// @param amount_ Native-token amount per payment (wei).
    /// @param intervalSeconds_ Seconds between payments (>= 60).
    /// @param payments_ How many payments the schedule will make.
    /// @return scheduleId_ The new schedule id.
    function createSchedule(address recipient_, uint256 amount_, uint256 intervalSeconds_, uint256 payments_)
        external
        payable
        returns (uint256 scheduleId_)
    {
        if (recipient_ == address(0)) revert InvalidRecipient();
        if (amount_ == 0) revert InvalidAmount();
        if (intervalSeconds_ < MIN_INTERVAL) revert InvalidInterval();
        if (payments_ == 0) revert InvalidPayments();

        uint256 required = amount_ * payments_ + GAS_RESERVE;
        if (msg.value < required) revert InsufficientDeposit(required, msg.value);

        scheduleId_ = nextScheduleId++;
        uint256 nextDue = block.timestamp + intervalSeconds_;
        schedules[scheduleId_] = Schedule({
            owner: msg.sender,
            recipient: recipient_,
            amount: amount_,
            intervalSeconds: intervalSeconds_,
            paymentsLeft: payments_,
            nextDue: nextDue,
            escrow: amount_ * payments_,
            active: true
        });

        emit ScheduleCreated(
            scheduleId_, msg.sender, recipient_, amount_, intervalSeconds_, payments_, nextDue
        );
    }

    /// @notice Add more payments to an existing schedule.
    function topUpSchedule(uint256 scheduleId_, uint256 extraPayments_) external payable {
        Schedule storage s = schedules[scheduleId_];
        if (!s.active) revert ScheduleNotActive();
        if (msg.sender != s.owner) revert NotScheduleOwner();
        if (extraPayments_ == 0) revert InvalidPayments();
        uint256 required = s.amount * extraPayments_;
        if (msg.value < required) revert InsufficientDeposit(required, msg.value);
        s.escrow += required;
        s.paymentsLeft += extraPayments_;
        emit ScheduleFunded(scheduleId_, extraPayments_, s.escrow);
    }

    /// @notice Cancel a schedule and refund the remaining escrow to the owner.
    function cancelSchedule(uint256 scheduleId_) external {
        Schedule storage s = schedules[scheduleId_];
        if (!s.active) revert ScheduleNotActive();
        if (msg.sender != s.owner) revert NotScheduleOwner();
        s.active = false;
        uint256 refund = s.escrow;
        s.escrow = 0;
        s.paymentsLeft = 0;
        if (refund > 0) {
            (bool ok,) = payable(s.owner).call{ value: refund }("");
            if (!ok) revert TransferFailed();
        }
        emit ScheduleCancelled(scheduleId_);
    }

    /// @notice Release one due payment. Called ONLY by the callback proxy on
    ///         behalf of the authorised reactive contract.
    /// @param reactive_ Injected by the network: the reactive contract that
    ///        requested this callback (must match _CALLBACK_SENDER).
    /// @param scheduleId_ The schedule to pay out.
    function release(address reactive_, uint256 scheduleId_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Schedule storage s = schedules[scheduleId_];
        if (!s.active) revert ScheduleNotActive();
        if (s.paymentsLeft == 0) revert ScheduleNotActive();
        if (block.timestamp < s.nextDue) revert PaymentNotDue(s.nextDue, block.timestamp);
        if (s.escrow < s.amount) revert InsufficientEscrow();

        s.escrow -= s.amount;
        s.paymentsLeft -= 1;
        s.nextDue += s.intervalSeconds;
        if (s.paymentsLeft == 0) s.active = false;

        (bool ok,) = payable(s.recipient).call{ value: s.amount }("");
        if (!ok) revert TransferFailed();

        emit PaymentReleased(scheduleId_, s.recipient, s.amount, s.paymentsLeft, s.nextDue);
    }

    /// @notice Settle outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Full schedule record (the public mapping getter returns a tuple;
    ///         this is the same data, kept for front-end convenience).
    function getSchedule(uint256 scheduleId_) external view returns (Schedule memory) {
        return schedules[scheduleId_];
    }
}
