// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./CreditRegistry.sol";
import "./ReservePool.sol";

/**
 * @title LendingCircle
 * @notice Manages a single lending circle with voting-based payout selection
 * @dev Implements credit-based limits, weighted voting, and reserve pool integration
 */
contract LendingCircle {

    // Enums
    enum CircleStatus {
        PENDING,
        ACTIVE,
        COMPLETED,
        CANCELLED
    }

    enum ExcessDistributionMethod {
        WITHDRAWABLE,
        AUTO_DEDUCT
    }

    // Constants for credit-based limits
    uint256 public constant MAX_CONTRIBUTION_PER_CREDIT = 1 ether; // 1 ETH per credit point
    uint256 public constant MAX_PARTICIPANTS_PER_CREDIT = 1; // 1 participant per credit point
    uint256 public constant MAX_EXPOSURE_PER_CREDIT = 10 ether; // 10 ETH per credit point

    // Circle parameters
    address public creator;
    address public coordinator;
    uint256 public monthlyContribution;
    uint256 public durationInMonths;
    uint256 public minParticipants;
    uint256 public maxParticipants;
    uint256 public reservePercentage; // 0-100
    ExcessDistributionMethod public excessDistributionMethod;

    // State
    CircleStatus public status;
    uint256 public currentMonth;
    uint256 public totalParticipants;
    uint256 public poolBalance;
    uint256 public totalReserveDeposited;

    // External contracts
    CreditRegistry public creditRegistry;
    ReservePool public reservePool;

    // Participant tracking
    struct Participant {
        address participant;
        bool isActive;
        bool hasReceivedPayout;
        bool isInDefault;
        uint256 withdrawableBalance;
        mapping(uint256 => bool) monthlyPayments; // month => paid
        mapping(uint256 => uint256) paymentTimestamp; // month => timestamp
    }

    mapping(address => Participant) public participants;
    address[] public participantList;

    // Voting system
    struct Vote {
        address voter;
        address candidate;
        uint256 weight;
        bool hasVoted;
    }

    struct Candidate {
        address candidate;
        address proposer;
        uint256 totalVotes;
        bool isActive;
    }

    struct PayoutProposal {
        uint256 endTime;
        bool executed;
        address winner;
        mapping(address => Candidate) candidates; // candidate address => Candidate
        address[] candidateList;
        mapping(address => Vote) votes; // voter => Vote
        address[] voters;
    }

    mapping(uint256 => PayoutProposal) public payoutProposals; // month => proposal
    uint256 public votingPeriod = 7 days;

    // Events
    event CircleCreated(
        address indexed creator,
        uint256 monthlyContribution,
        uint256 durationInMonths,
        uint256 minParticipants,
        uint256 maxParticipants
    );
    event ParticipantJoined(address indexed participant);
    event ParticipantApproved(address indexed participant);
    event ParticipantRejected(address indexed participant);
    event CircleActivated(uint256 totalParticipants);
    event ContributionMade(address indexed participant, uint256 month, uint256 amount);
    event LatePaymentRecorded(address indexed participant, uint256 month);
    event DefaultRecorded(address indexed participant, uint256 month);
    event PayoutProposed(address indexed proposer, address indexed candidate, uint256 month);
    event VoteCast(address indexed voter, address indexed candidate, uint256 weight, uint256 month);
    event PayoutExecuted(address indexed recipient, uint256 amount, uint256 month);
    event ExcessDistributed(uint256 month, uint256 totalAmount);
    event CircleCompleted();
    event CoordinatorChanged(address indexed oldCoordinator, address indexed newCoordinator);

    // Modifiers
    modifier onlyCoordinator() {
        require(msg.sender == coordinator, "LendingCircle: Only coordinator can call");
        _;
    }

    modifier onlyActiveParticipant() {
        require(
            participants[msg.sender].isActive && !participants[msg.sender].isInDefault,
            "LendingCircle: Only active participants can call"
        );
        _;
    }

    modifier onlyActiveCircle() {
        require(status == CircleStatus.ACTIVE, "LendingCircle: Circle must be active");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "LendingCircle: Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    bool private _locked;

    /**
     * @notice Constructor - creates a new lending circle
     * @param _creator Address of the circle creator
     * @param _monthlyContribution Monthly contribution amount in wei
     * @param _durationInMonths Duration of the circle in months
     * @param _minParticipants Minimum number of participants required
     * @param _maxParticipants Maximum number of participants allowed
     * @param _reservePercentage Percentage of contributions going to reserve (0-100)
     * @param _excessDistributionMethod How to handle excess funds
     * @param _creditRegistry Address of CreditRegistry contract
     * @param _reservePool Address of ReservePool contract
     */
    constructor(
        address _creator,
        uint256 _monthlyContribution,
        uint256 _durationInMonths,
        uint256 _minParticipants,
        uint256 _maxParticipants,
        uint256 _reservePercentage,
        ExcessDistributionMethod _excessDistributionMethod,
        address _creditRegistry,
        address payable _reservePool
    ) {
        require(_creator != address(0), "LendingCircle: Invalid creator");
        require(_monthlyContribution > 0, "LendingCircle: Contribution must be greater than 0");
        require(_durationInMonths > 0, "LendingCircle: Duration must be greater than 0");
        require(_minParticipants >= 2, "LendingCircle: Minimum 2 participants required");
        require(_maxParticipants >= _minParticipants, "LendingCircle: Max must be >= min");
        require(_reservePercentage <= 100, "LendingCircle: Reserve percentage must be <= 100");
        require(_creditRegistry != address(0), "LendingCircle: Invalid credit registry");
        require(_reservePool != address(0), "LendingCircle: Invalid reserve pool");

        creator = _creator;
        coordinator = _creator;
        monthlyContribution = _monthlyContribution;
        durationInMonths = _durationInMonths;
        minParticipants = _minParticipants;
        maxParticipants = _maxParticipants;
        reservePercentage = _reservePercentage;
        excessDistributionMethod = _excessDistributionMethod;
        creditRegistry = CreditRegistry(_creditRegistry);
        reservePool = ReservePool(_reservePool);

        status = CircleStatus.PENDING;
        currentMonth = 0;

        // Enforce credit-based limits
        uint256 creatorCredit = creditRegistry.getCreditScore(_creator);
        require(
            _monthlyContribution <= creatorCredit * MAX_CONTRIBUTION_PER_CREDIT,
            "LendingCircle: Contribution exceeds credit limit"
        );
        require(
            _maxParticipants <= creatorCredit * MAX_PARTICIPANTS_PER_CREDIT,
            "LendingCircle: Max participants exceeds credit limit"
        );
        require(
            (_monthlyContribution * _maxParticipants * _durationInMonths) <= creatorCredit * MAX_EXPOSURE_PER_CREDIT,
            "LendingCircle: Total exposure exceeds credit limit"
        );

        // Add creator as first participant
        participants[_creator].participant = _creator;
        participants[_creator].isActive = true;
        participantList.push(_creator);
        totalParticipants = 1;

        // Not recorded here: at construction time this contract's own address
        // isn't verified in CreditRegistry yet (verification can only happen
        // after deployment, once the address is known). The factory records
        // the creator's join right after verifying this circle.

        emit CircleCreated(_creator, _monthlyContribution, _durationInMonths, _minParticipants, _maxParticipants);
    }

    /**
     * @notice Request to join the circle
     */
    function requestToJoin() external {
        require(status == CircleStatus.PENDING, "LendingCircle: Circle not accepting new members");
        require(totalParticipants < maxParticipants, "LendingCircle: Circle is full");
        require(!participants[msg.sender].isActive, "LendingCircle: Already a participant");
        require(msg.sender != creator, "LendingCircle: Creator is already a participant");

        participants[msg.sender].participant = msg.sender;
        participantList.push(msg.sender);
        totalParticipants++;

        creditRegistry.recordCircleJoin(msg.sender);

        emit ParticipantJoined(msg.sender);
    }

    /**
     * @notice Approve a participant (coordinator only)
     * @param participant Address to approve
     */
    function approveParticipant(address participant) external onlyCoordinator {
        require(status == CircleStatus.PENDING, "LendingCircle: Circle not in pending status");
        require(participants[participant].participant == participant, "LendingCircle: Participant not found");
        require(!participants[participant].isActive, "LendingCircle: Already approved");

        participants[participant].isActive = true;

        emit ParticipantApproved(participant);

        // Auto-activate if minimum approved (active) participants reached.
        // totalParticipants also counts pending, unapproved join requests, so
        // it isn't a valid proxy for "enough participants are actually active".
        if (_getActiveParticipantCount() >= minParticipants) {
            _activateCircle();
        }
    }

    /**
     * @notice Reject a participant (coordinator only)
     * @param participant Address to reject
     */
    function rejectParticipant(address participant) external onlyCoordinator {
        require(status == CircleStatus.PENDING, "LendingCircle: Circle not in pending status");
        require(participants[participant].participant == participant, "LendingCircle: Participant not found");
        require(!participants[participant].isActive, "LendingCircle: Cannot reject active participant");

        // Remove from participant list
        for (uint256 i = 0; i < participantList.length; i++) {
            if (participantList[i] == participant) {
                participantList[i] = participantList[participantList.length - 1];
                participantList.pop();
                break;
            }
        }
        totalParticipants--;

        delete participants[participant];

        emit ParticipantRejected(participant);
    }

    /**
     * @notice Make monthly contribution
     * @param month Month number (0-indexed)
     */
    function makeContribution(uint256 month) external payable onlyActiveParticipant onlyActiveCircle {
        require(month == currentMonth, "LendingCircle: Invalid month");
        require(!participants[msg.sender].monthlyPayments[month], "LendingCircle: Already paid for this month");

        uint256 contributionAmount = monthlyContribution;
        
        // Handle auto-deduct from excess balance if applicable
        if (excessDistributionMethod == ExcessDistributionMethod.AUTO_DEDUCT && 
            participants[msg.sender].withdrawableBalance > 0) {
            uint256 excessBalance = participants[msg.sender].withdrawableBalance;
            if (excessBalance >= contributionAmount) {
                // Excess covers full contribution
                participants[msg.sender].withdrawableBalance = excessBalance - contributionAmount;
                contributionAmount = 0;
            } else {
                // Excess covers partial contribution
                contributionAmount = contributionAmount - excessBalance;
                participants[msg.sender].withdrawableBalance = 0;
            }
        }

        require(msg.value == contributionAmount, "LendingCircle: Incorrect contribution amount");

        // Record payment
        participants[msg.sender].monthlyPayments[month] = true;
        participants[msg.sender].paymentTimestamp[month] = block.timestamp;

        // Split payment: (100 - reservePercentage)% to pool, reservePercentage% to reserve
        uint256 reserveAmount = (msg.value * reservePercentage) / 100;
        uint256 poolAmount = msg.value - reserveAmount;

        poolBalance += poolAmount;
        totalReserveDeposited += reserveAmount;

        // Send reserve to ReservePool
        if (reserveAmount > 0) {
            (bool success, ) = address(reservePool).call{value: reserveAmount}("");
            require(success, "LendingCircle: Reserve deposit failed");
        }

        // Record on-time payment
        creditRegistry.recordOnTimePayment(msg.sender);

        emit ContributionMade(msg.sender, month, msg.value);
    }

    /**
     * @notice Propose a participant for payout
     * @param candidate Address of the candidate
     * @param month Month number
     */
    function proposePayout(address candidate, uint256 month) external onlyActiveParticipant onlyActiveCircle {
        require(month == currentMonth, "LendingCircle: Can only propose for current month");
        require(participants[candidate].isActive, "LendingCircle: Candidate must be active");
        require(!participants[candidate].hasReceivedPayout, "LendingCircle: Candidate already received payout");
        require(!participants[candidate].isInDefault, "LendingCircle: Candidate is in default");
        
        PayoutProposal storage proposal = payoutProposals[month];
        
        // Initialize proposal if first candidate
        if (proposal.endTime == 0) {
            proposal.endTime = block.timestamp + votingPeriod;
            proposal.executed = false;
        }
        
        require(block.timestamp < proposal.endTime, "LendingCircle: Voting period ended");
        require(!proposal.candidates[candidate].isActive, "LendingCircle: Candidate already proposed");

        proposal.candidates[candidate] = Candidate({
            candidate: candidate,
            proposer: msg.sender,
            totalVotes: 0,
            isActive: true
        });
        proposal.candidateList.push(candidate);

        emit PayoutProposed(msg.sender, candidate, month);
    }

    /**
     * @notice Vote on payout proposal
     * @param month Month number
     * @param candidate Address of the candidate to vote for
     */
    function vote(uint256 month, address candidate) external onlyActiveParticipant onlyActiveCircle {
        PayoutProposal storage proposal = payoutProposals[month];
        require(proposal.endTime > 0, "LendingCircle: No proposal exists for this month");
        require(block.timestamp < proposal.endTime, "LendingCircle: Voting period ended");
        require(!proposal.votes[msg.sender].hasVoted, "LendingCircle: Already voted");
        require(proposal.candidates[candidate].isActive, "LendingCircle: Invalid candidate");

        uint256 voteWeight = creditRegistry.getCreditScore(msg.sender);
        require(voteWeight > 0, "LendingCircle: Invalid vote weight");

        proposal.votes[msg.sender] = Vote({
            voter: msg.sender,
            candidate: candidate,
            weight: voteWeight,
            hasVoted: true
        });
        proposal.voters.push(msg.sender);
        proposal.candidates[candidate].totalVotes = proposal.candidates[candidate].totalVotes + voteWeight;

        emit VoteCast(msg.sender, candidate, voteWeight, month);
    }

    /**
     * @notice Execute payout after voting period
     * @param month Month number
     */
    function executePayout(uint256 month) external nonReentrant onlyActiveCircle {
        PayoutProposal storage proposal = payoutProposals[month];
        require(proposal.endTime > 0, "LendingCircle: No proposal exists");
        require(block.timestamp >= proposal.endTime, "LendingCircle: Voting period not ended");
        require(!proposal.executed, "LendingCircle: Payout already executed");
        require(month == currentMonth, "LendingCircle: Can only execute for current month");

        // Select winner: highest votes, tie-break by credit score
        address recipient = _selectWinner(month);
        require(recipient != address(0), "LendingCircle: No valid winner");
        require(participants[recipient].isActive, "LendingCircle: Recipient must be active");
        require(!participants[recipient].hasReceivedPayout, "LendingCircle: Recipient already received payout");
        require(!participants[recipient].isInDefault, "LendingCircle: Recipient is in default");

        // Calculate payout amount: total contributions to pool for this month
        // Each active participant contributes (monthlyContribution * (100 - reservePercentage) / 100) to pool
        uint256 activeCount = _getActiveParticipantCount();
        uint256 expectedPoolPerParticipant = (monthlyContribution * (100 - reservePercentage)) / 100;
        uint256 expectedPool = expectedPoolPerParticipant * activeCount;
        uint256 payoutAmount = expectedPool;

        // If insufficient, pull from reserve pool
        if (poolBalance < payoutAmount) {
            uint256 shortfall = payoutAmount - poolBalance;
            reservePool.withdraw(shortfall, address(this));
            poolBalance += shortfall;
        }

        require(poolBalance >= payoutAmount, "LendingCircle: Insufficient funds for payout");

        // Mark recipient as paid
        participants[recipient].hasReceivedPayout = true;
        poolBalance -= payoutAmount;
        proposal.executed = true;
        proposal.winner = recipient;

        // Transfer payout
        (bool success, ) = recipient.call{value: payoutAmount}("");
        require(success, "LendingCircle: Payout transfer failed");

        // Update credit registry positively
        creditRegistry.recordOnTimePayment(recipient);

        // Handle excess funds
        _distributeExcess(month);

        // Advance to next month
        currentMonth++;
        if (currentMonth >= durationInMonths) {
            _completeCircle();
        }

        emit PayoutExecuted(recipient, payoutAmount, month);
    }

    /**
     * @notice Internal: Select winner based on votes and credit score
     * @param month Month number
     * @return winner Address of the winning candidate
     */
    function _selectWinner(uint256 month) internal view returns (address winner) {
        PayoutProposal storage proposal = payoutProposals[month];
        
        if (proposal.candidateList.length == 0) {
            return address(0);
        }

        address bestCandidate = address(0);
        uint256 bestVotes = 0;
        uint256 bestCredit = 0;

        for (uint256 i = 0; i < proposal.candidateList.length; i++) {
            address candidate = proposal.candidateList[i];
            Candidate storage cand = proposal.candidates[candidate];
            
            if (!cand.isActive) continue;
            if (participants[candidate].hasReceivedPayout) continue;
            if (participants[candidate].isInDefault) continue;

            uint256 candidateVotes = cand.totalVotes;
            if (candidateVotes == 0) continue; // must receive at least one vote to win

            uint256 candidateCredit = creditRegistry.getCreditScore(candidate);

            // Select candidate with most votes, or if tied, highest credit score
            if (candidateVotes > bestVotes ||
                (candidateVotes == bestVotes && candidateCredit > bestCredit)) {
                bestCandidate = candidate;
                bestVotes = candidateVotes;
                bestCredit = candidateCredit;
            }
        }

        return bestCandidate;
    }

    /**
     * @notice Record late payment for a participant
     * @param participant Address of the participant
     * @param month Month number
     */
    function recordLatePayment(address participant, uint256 month) external onlyCoordinator onlyActiveCircle {
        require(participants[participant].isActive, "LendingCircle: Participant not found");
        require(!participants[participant].monthlyPayments[month], "LendingCircle: Payment already recorded");

        participants[participant].monthlyPayments[month] = true;
        creditRegistry.recordLatePayment(participant);

        emit LatePaymentRecorded(participant, month);
    }

    /**
     * @notice Record default for a participant
     * @param participant Address of the participant
     * @param month Month number
     */
    function recordDefault(address participant, uint256 month) external onlyCoordinator onlyActiveCircle {
        require(participants[participant].isActive, "LendingCircle: Participant not found");

        participants[participant].isInDefault = true;
        creditRegistry.recordDefault(participant);

        emit DefaultRecorded(participant, month);
    }

    /**
     * @notice Withdraw excess balance (if method is WITHDRAWABLE)
     */
    function withdrawExcess() external onlyActiveParticipant {
        require(
            excessDistributionMethod == ExcessDistributionMethod.WITHDRAWABLE,
            "LendingCircle: Excess not withdrawable"
        );
        require(participants[msg.sender].withdrawableBalance > 0, "LendingCircle: No balance to withdraw");

        uint256 amount = participants[msg.sender].withdrawableBalance;
        participants[msg.sender].withdrawableBalance = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "LendingCircle: Withdrawal failed");
    }

    /**
     * @notice Get active participant count
     */
    function getActiveParticipantCount() external view returns (uint256) {
        return _getActiveParticipantCount();
    }

    /**
     * @notice Get participant payment status for a month
     */
    function hasPaidForMonth(address participant, uint256 month) external view returns (bool) {
        return participants[participant].monthlyPayments[month];
    }

    /**
     * @notice Get candidate vote count for a month
     * @param month Month number
     * @param candidate Candidate address
     * @return Vote count for the candidate
     */
    function getCandidateVotes(uint256 month, address candidate) external view returns (uint256) {
        return payoutProposals[month].candidates[candidate].totalVotes;
    }

    /**
     * @notice Get all candidates for a month
     * @param month Month number
     * @return Array of candidate addresses
     */
    function getCandidates(uint256 month) external view returns (address[] memory) {
        return payoutProposals[month].candidateList;
    }

    /**
     * @notice Get winner for a month (if payout executed)
     * @param month Month number
     * @return Winner address (address(0) if not executed)
     */
    function getWinner(uint256 month) external view returns (address) {
        return payoutProposals[month].winner;
    }

    /**
     * @notice Check if voting period has ended for a month
     * @param month Month number
     * @return True if voting period has ended
     */
    function isVotingPeriodEnded(uint256 month) external view returns (bool) {
        return block.timestamp >= payoutProposals[month].endTime && payoutProposals[month].endTime > 0;
    }

    /**
     * @notice Internal: Activate the circle
     */
    function _activateCircle() internal {
        require(_getActiveParticipantCount() >= minParticipants, "LendingCircle: Not enough participants");
        status = CircleStatus.ACTIVE;
        emit CircleActivated(totalParticipants);
    }

    /**
     * @notice Internal: Complete the circle
     */
    function _completeCircle() internal {
        status = CircleStatus.COMPLETED;

        // Record completion for all active participants
        for (uint256 i = 0; i < participantList.length; i++) {
            if (participants[participantList[i]].isActive && !participants[participantList[i]].isInDefault) {
                creditRegistry.recordCircleCompletion(participantList[i]);
            }
        }

        emit CircleCompleted();
    }

    /**
     * @notice Internal: Distribute excess funds
     * @param month Month number
     */
    function _distributeExcess(uint256 month) internal {
        // Calculate expected pool for this month (after payout)
        uint256 activeCount = _getActiveParticipantCount();
        if (activeCount == 0) return;

        // Expected: all active participants contributed their share to pool (excluding reserve)
        uint256 expectedPoolPerParticipant = (monthlyContribution * (100 - reservePercentage)) / 100;
        uint256 expectedTotalPool = expectedPoolPerParticipant * activeCount;

        // Actual pool balance remaining after payout
        // Note: payoutAmount was already deducted from poolBalance
        if (poolBalance > expectedTotalPool) {
            uint256 excess = poolBalance - expectedTotalPool;
            uint256 perParticipant = excess / activeCount;

            // Distribute excess to all active participants
            for (uint256 i = 0; i < participantList.length; i++) {
                address participant = participantList[i];
                if (participants[participant].isActive && !participants[participant].isInDefault) {
                    participants[participant].withdrawableBalance += perParticipant;
                }
            }

            // Deduct from pool balance
            poolBalance -= excess;

            emit ExcessDistributed(month, excess);
        }
    }

    /**
     * @notice Internal: Get active participant count
     */
    function _getActiveParticipantCount() internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < participantList.length; i++) {
            if (participants[participantList[i]].isActive && !participants[participantList[i]].isInDefault) {
                count++;
            }
        }
        return count;
    }

    /**
     * @notice Receive function to accept ETH (from reserve pool withdrawals)
     */
    receive() external payable {
        poolBalance += msg.value;
    }
}

