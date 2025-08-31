// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// OpenZeppelin dependencies via GitHub URLs
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.9/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title Secret Santa Protocol - Trustless P2P Gifting
 * @notice A decentralized protocol for organizing trustless Secret Santa gift exchanges
 */
contract SecretSantaProtocol is ReentrancyGuard, Ownable {
    // ----------------------- Errors -----------------------
    error InvalidExchangeState();
    error InsufficientDeposit();
    error RegistrationClosed();
    error NotParticipant();
    error AlreadyRegistered();
    error GiftAlreadySubmitted();
    error InvalidGiftProof();
    error ClaimNotAllowed();
    error ExchangeNotFound();
    error DeadlinePassed();

    // ----------------------- Events -----------------------
    event ExchangeCreated(uint256 indexed exchangeId, address indexed organizer, uint256 giftAmount, uint256 registrationDeadline, uint256 revealDeadline);
    event ParticipantRegistered(uint256 indexed exchangeId, address indexed participant, uint256 participantCount);
    event AssignmentsRevealed(uint256 indexed exchangeId, bytes32 merkleRoot, uint256 timestamp);
    event GiftSubmitted(uint256 indexed exchangeId, address indexed giver, bytes32 giftHash, uint256 timestamp);
    event GiftClaimed(uint256 indexed exchangeId, address indexed recipient, uint256 amount, uint256 bonus);
    event ExchangeFinalized(uint256 indexed exchangeId, uint256 successfulPairs, uint256 totalRewards);

    // ----------------------- Enums -----------------------
    enum ExchangeState {
        Registration,
        Assignment,
        Active,
        Claiming,
        Finalized
    }

    // ----------------------- Structs -----------------------
    struct Exchange {
        address organizer;
        uint256 giftAmount;
        uint256 registrationDeadline;
        uint256 revealDeadline;
        uint256 claimDeadline;
        ExchangeState state;
        uint256 participantCount;
        uint256 totalDeposits;
        bytes32 assignmentMerkleRoot;
        uint256 successfulGifts;
        address[] participantList;
    }

    struct GiftProof {
        bytes32[] merkleProof;
        address recipient;
        uint256 nonce;
    }

    // ----------------------- State -----------------------
    uint256 public nextExchangeId = 1;
    uint256 public constant MIN_PARTICIPANTS = 3;
    uint256 public constant MAX_PARTICIPANTS = 100;
    uint256 public constant BONUS_PERCENTAGE = 10;
    uint256 public constant PLATFORM_FEE = 250;

    mapping(uint256 => Exchange) public exchanges;
    mapping(uint256 => mapping(address => bool)) public participants;
    mapping(uint256 => mapping(address => bool)) public hasSubmittedGift;
    mapping(uint256 => mapping(address => bytes32)) public giftHashes;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(address => uint256[]) public userExchanges;

    uint256 public totalExchanges;
    uint256 public totalParticipants;
    uint256 public totalGiftsExchanged;
    uint256 public totalValueTransferred;

    // ----------------------- Modifiers -----------------------
    modifier validExchange(uint256 exchangeId) {
        if (exchangeId == 0 || exchangeId >= nextExchangeId) revert ExchangeNotFound();
        _;
    }

    modifier onlyParticipant(uint256 exchangeId) {
        if (!participants[exchangeId][msg.sender]) revert NotParticipant();
        _;
    }

    modifier inState(uint256 exchangeId, ExchangeState requiredState) {
        if (exchanges[exchangeId].state != requiredState) revert InvalidExchangeState();
        _;
    }

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    // ----------------------- Constructor -----------------------
    constructor() {}

    // ----------------------- Core Functions -----------------------
    function createExchange(uint256 giftAmount, uint256 registrationDuration, uint256 exchangeDuration) external payable nonReentrant returns (uint256 exchangeId) {
        if (msg.value < giftAmount) revert InsufficientDeposit();

        exchangeId = nextExchangeId++;
        Exchange storage newExchange = exchanges[exchangeId];

        newExchange.organizer = msg.sender;
        newExchange.giftAmount = giftAmount;
        newExchange.registrationDeadline = block.timestamp + registrationDuration;
        newExchange.revealDeadline = newExchange.registrationDeadline + 1 days;
        newExchange.claimDeadline = newExchange.revealDeadline + exchangeDuration;
        newExchange.state = ExchangeState.Registration;

        _registerParticipant(exchangeId, msg.sender, msg.value);
        totalExchanges++;

        emit ExchangeCreated(exchangeId, msg.sender, giftAmount, newExchange.registrationDeadline, newExchange.revealDeadline);
    }

    function registerForExchange(uint256 exchangeId) external payable validExchange(exchangeId) inState(exchangeId, ExchangeState.Registration) beforeDeadline(exchanges[exchangeId].registrationDeadline) nonReentrant {
        Exchange storage exchange = exchanges[exchangeId];

        if (participants[exchangeId][msg.sender]) revert AlreadyRegistered();
        if (msg.value < exchange.giftAmount) revert InsufficientDeposit();
        if (exchange.participantCount >= MAX_PARTICIPANTS) revert RegistrationClosed();

        _registerParticipant(exchangeId, msg.sender, msg.value);
    }

    function revealAssignments(uint256 exchangeId, bytes32 merkleRoot) external validExchange(exchangeId) inState(exchangeId, ExchangeState.Registration) nonReentrant {
        Exchange storage exchange = exchanges[exchangeId];

        if (block.timestamp < exchange.registrationDeadline && msg.sender != exchange.organizer) revert DeadlinePassed();
        if (exchange.participantCount < MIN_PARTICIPANTS) revert InvalidExchangeState();

        exchange.assignmentMerkleRoot = merkleRoot;
        exchange.state = ExchangeState.Active;

        emit AssignmentsRevealed(exchangeId, merkleRoot, block.timestamp);
    }

    function submitGift(uint256 exchangeId, bytes32 giftHash, GiftProof memory proof) external validExchange(exchangeId) onlyParticipant(exchangeId) inState(exchangeId, ExchangeState.Active) beforeDeadline(exchanges[exchangeId].claimDeadline) nonReentrant {
        Exchange storage exchange = exchanges[exchangeId];

        if (hasSubmittedGift[exchangeId][msg.sender]) revert GiftAlreadySubmitted();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, proof.recipient, proof.nonce));
        if (!MerkleProof.verify(proof.merkleProof, exchange.assignmentMerkleRoot, leaf)) revert InvalidGiftProof();

        hasSubmittedGift[exchangeId][msg.sender] = true;
        giftHashes[exchangeId][msg.sender] = giftHash;
        exchange.successfulGifts++;
        totalGiftsExchanged++;

        emit GiftSubmitted(exchangeId, msg.sender, giftHash, block.timestamp);

        if (exchange.successfulGifts == exchange.participantCount) {
            exchange.state = ExchangeState.Claiming;
        }
    }

    function claimGift(uint256 exchangeId) external validExchange(exchangeId) onlyParticipant(exchangeId) nonReentrant {
        Exchange storage exchange = exchanges[exchangeId];

        if (exchange.state != ExchangeState.Claiming && block.timestamp <= exchange.claimDeadline) revert ClaimNotAllowed();
        if (hasClaimed[exchangeId][msg.sender]) revert ClaimNotAllowed();
        if (!hasSubmittedGift[exchangeId][msg.sender]) revert ClaimNotAllowed();

        hasClaimed[exchangeId][msg.sender] = true;

        uint256 baseReward = exchange.giftAmount;
        uint256 bonus = _calculateBonus(exchangeId, msg.sender);
        uint256 totalReward = baseReward + bonus;

        uint256 platformFee = (totalReward * PLATFORM_FEE) / 10000;
        uint256 finalReward = totalReward - platformFee;

        totalValueTransferred += finalReward;

        (bool success, ) = payable(msg.sender).call{value: finalReward}("");
        require(success, "Transfer failed");

        emit GiftClaimed(exchangeId, msg.sender, finalReward, bonus);
    }

    /**
     * @notice Batch-claim gifts from multiple exchanges in one transaction.
     * @dev Aggregates final rewards across provided exchangeIds and performs a single transfer to save gas.
     *      For each exchange, the same validation rules as single `claimGift` apply:
     *        - Caller must be participant
     *        - Exchange must be in Claiming state OR claimDeadline must have passed
     *        - Caller must have submitted a gift and not have already claimed
     * @param exchangeIds Array of exchange IDs to claim rewards from.
     */
    function batchClaim(uint256[] calldata exchangeIds) external nonReentrant {
        uint256 totalFinalPayout = 0;
        uint256 len = exchangeIds.length;
        require(len > 0, "No exchanges provided");

        for (uint256 i = 0; i < len; ++i) {
            uint256 exchangeId = exchangeIds[i];

            // validate exchange id
            if (exchangeId == 0 || exchangeId >= nextExchangeId) revert ExchangeNotFound();

            Exchange storage exchange = exchanges[exchangeId];

            // same claim validation logic as claimGift
            if (exchange.state != ExchangeState.Claiming && block.timestamp <= exchange.claimDeadline) revert ClaimNotAllowed();
            if (!participants[exchangeId][msg.sender]) revert NotParticipant();
            if (hasClaimed[exchangeId][msg.sender]) revert ClaimNotAllowed();
            if (!hasSubmittedGift[exchangeId][msg.sender]) revert ClaimNotAllowed();

            // mark claimed immediately to prevent re-entrancy style reuse inside loop
            hasClaimed[exchangeId][msg.sender] = true;

            uint256 baseReward = exchange.giftAmount;
            uint256 bonus = _calculateBonus(exchangeId, msg.sender);
            uint256 totalReward = baseReward + bonus;

            uint256 platformFee = (totalReward * PLATFORM_FEE) / 10000;
            uint256 finalReward = totalReward - platformFee;

            totalFinalPayout += finalReward;

            emit GiftClaimed(exchangeId, msg.sender, finalReward, bonus);
        }

        require(totalFinalPayout > 0, "No payout available");

        totalValueTransferred += totalFinalPayout;

        (bool success, ) = payable(msg.sender).call{value: totalFinalPayout}("");
        require(success, "Transfer failed");
    }

    // ----------------------- Internal -----------------------
    function _registerParticipant(uint256 exchangeId, address participant, uint256 deposit) internal {
        Exchange storage exchange = exchanges[exchangeId];
        participants[exchangeId][participant] = true;
        exchange.participantList.push(participant);
        exchange.participantCount++;
        exchange.totalDeposits += deposit;
        userExchanges[participant].push(exchangeId);
        totalParticipants++;

        emit ParticipantRegistered(exchangeId, participant, exchange.participantCount);
    }

    function _calculateBonus(uint256 exchangeId, address) internal view returns (uint256) {
        Exchange storage exchange = exchanges[exchangeId];
        uint256 midpoint = exchange.revealDeadline + ((exchange.claimDeadline - exchange.revealDeadline) / 2);

        if (block.timestamp <= midpoint) {
            return (exchange.giftAmount * BONUS_PERCENTAGE) / 100;
        }

        return 0;
    }

    // ----------------------- Views -----------------------
    function getExchangeDetails(uint256 exchangeId) external view validExchange(exchangeId) returns (address, uint256, uint256, uint256, uint256, ExchangeState, uint256, uint256) {
        Exchange storage e = exchanges[exchangeId];
        return (e.organizer, e.giftAmount, e.registrationDeadline, e.revealDeadline, e.claimDeadline, e.state, e.participantCount, e.successfulGifts);
    }

    function getParticipants(uint256 exchangeId) external view validExchange(exchangeId) returns (address[] memory) {
        return exchanges[exchangeId].participantList;
    }

    function getUserExchanges(address user) external view returns (uint256[] memory) {
        return userExchanges[user];
    }

    function isParticipant(uint256 exchangeId, address user) external view returns (bool) {
        return participants[exchangeId][user];
    }

    function hasUserSubmittedGift(uint256 exchangeId, address user) external view returns (bool) {
        return hasSubmittedGift[exchangeId][user];
    }

    function getGiftHash(uint256 exchangeId, address user) external view returns (bytes32) {
        return giftHashes[exchangeId][user];
    }

    function hasUserClaimed(uint256 exchangeId, address user) external view returns (bool) {
        return hasClaimed[exchangeId][user];
    }

    function getProtocolStats() external view returns (uint256, uint256, uint256, uint256) {
        return (totalExchanges, totalParticipants, totalGiftsExchanged, totalValueTransferred);
    }

    // ----------------------- Admin -----------------------
    function withdrawPlatformFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");

        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Transfer failed");
    }

    function emergencyPause(uint256 exchangeId) external onlyOwner validExchange(exchangeId) {
        exchanges[exchangeId].state = ExchangeState.Finalized;
    }

    // ----------------------- Fallback -----------------------
    receive() external payable {}
    fallback() external payable {
        revert("Function not found");
    }
}
