// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./CreditRegistry.sol";
import "./ReservePool.sol";
import "./LendingCircle.sol";

/**
 * @title LendingCircleFactory
 * @notice Factory contract for creating new lending circles
 * @dev Manages circle creation and coordinates between CreditRegistry, ReservePool, and LendingCircle
 */
contract LendingCircleFactory {
    CreditRegistry public creditRegistry;
    ReservePool public reservePool;

    address[] public circles;
    mapping(address => bool) public isCircle;
    mapping(address => address[]) public userCircles; // user => circles[]

    // Events
    event CircleCreated(
        address indexed creator,
        address indexed circle,
        uint256 monthlyContribution,
        uint256 durationInMonths,
        uint256 minParticipants,
        uint256 maxParticipants
    );

    /**
     * @notice Constructor
     * @param _creditRegistry Address of CreditRegistry contract
     * @param _reservePool Address of ReservePool contract
     */
    constructor(address _creditRegistry, address payable _reservePool) {
        require(_creditRegistry != address(0), "LendingCircleFactory: Invalid credit registry");
        require(_reservePool != address(0), "LendingCircleFactory: Invalid reserve pool");

        creditRegistry = CreditRegistry(_creditRegistry);
        reservePool = ReservePool(_reservePool);
    }

    /**
     * @notice Create a new lending circle
     * @param monthlyContribution Monthly contribution amount in wei
     * @param durationInMonths Duration of the circle in months
     * @param minParticipants Minimum number of participants required
     * @param maxParticipants Maximum number of participants allowed
     * @param reservePercentage Percentage of contributions going to reserve (0-100)
     * @param excessDistributionMethod How to handle excess funds (0 = WITHDRAWABLE, 1 = AUTO_DEDUCT)
     * @return circle Address of the newly created LendingCircle contract
     */
    function createCircle(
        uint256 monthlyContribution,
        uint256 durationInMonths,
        uint256 minParticipants,
        uint256 maxParticipants,
        uint256 reservePercentage,
        LendingCircle.ExcessDistributionMethod excessDistributionMethod
    ) external returns (address circle) {
        // Validate creator has sufficient credit score
        uint256 creatorCredit = creditRegistry.getCreditScore(msg.sender);
        require(creatorCredit >= 300, "LendingCircleFactory: Insufficient credit score to create circle");

        // Create new LendingCircle
        LendingCircle newCircle = new LendingCircle(
            msg.sender,
            monthlyContribution,
            durationInMonths,
            minParticipants,
            maxParticipants,
            reservePercentage,
            excessDistributionMethod,
            address(creditRegistry),
            payable(address(reservePool))
        );

        circle = address(newCircle);

        // Register circle
        circles.push(circle);
        isCircle[circle] = true;
        userCircles[msg.sender].push(circle);

        // Verify circle in ReservePool and CreditRegistry
        reservePool.verifyCircle(circle);
        creditRegistry.verifyCircle(circle);

        // The circle's constructor couldn't record this itself: it wasn't
        // verified in CreditRegistry until the line above, which can only
        // run after deployment (its address wasn't known beforehand).
        creditRegistry.recordCircleJoin(msg.sender);

        emit CircleCreated(
            msg.sender,
            circle,
            monthlyContribution,
            durationInMonths,
            minParticipants,
            maxParticipants
        );

        return circle;
    }

    /**
     * @notice Get total number of circles created
     * @return Total count
     */
    function getCircleCount() external view returns (uint256) {
        return circles.length;
    }

    /**
     * @notice Get all circles created by a user
     * @param user Address of the user
     * @return Array of circle addresses
     */
    function getUserCircles(address user) external view returns (address[] memory) {
        return userCircles[user];
    }

    /**
     * @notice Get all circles (paginated)
     * @param offset Starting index
     * @param limit Number of circles to return
     * @return Array of circle addresses
     */
    function getCircles(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 length = circles.length;
        if (offset >= length) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }

        uint256 resultLength = end - offset;
        address[] memory result = new address[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            result[i] = circles[offset + i];
        }

        return result;
    }
}
