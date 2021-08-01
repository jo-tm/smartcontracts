/*
Original work taken from https://github.com/tapmydata/tap-protocol, which 
was based on https://gist.github.com/rstormsf/7cfb0c6b7a835c0c67b4a394b4fd9383.
*/
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VestingVault is Ownable {

    struct Grant {
        uint256 startTime;
        uint256 amount;
        uint16 vestingDuration;
        uint16 daysClaimed;
        uint256 totalClaimed;
        address recipient;
    }

    event GrantAdded(address indexed recipient);
    event GrantTokensClaimed(address indexed recipient, uint256 amountClaimed);
    event GrantRevoked(address recipient, uint256 amountVested, uint256 amountNotVested);

    ERC20 public token;
    
    mapping (address => Grant) private tokenGrants;

    /**
     * Granularity for vesting periods, in days. Vesting amounts will be released in multiples of
     * this period.
     */
    uint16 public vestingGranularityDays;

    constructor(ERC20 _token, uint16 _vestingGranularityDays) {
        require(address(_token) != address(0));
        token = _token;
        vestingGranularityDays = _vestingGranularityDays;
    }
    
    function addTokenGrant(
        address _recipient,
        uint256 _amount,
        uint16 _vestingDurationInDays,
        uint16 _vestingCliffInDays    
    ) 
        external
        onlyOwner
    {
        require(tokenGrants[_recipient].amount == 0, "Grant already exists, must revoke first.");
        require(_vestingCliffInDays <= 10*365, "Cliff greater than 10 years");
        require(_vestingDurationInDays <= 25*365, "Duration greater than 25 years");
        require(_vestingDurationInDays % vestingGranularityDays == 0, "Duration must be an exact multiple of granularity");
        
        uint256 amountVestedPerPeriod = _amount / (_vestingDurationInDays / vestingGranularityDays);
        require(amountVestedPerPeriod > 0, "amountVestedPerPeriod > 0");

        // Transfer the grant tokens under the control of the vesting contract
        require(token.transferFrom(owner(), address(this), _amount));

        Grant memory grant = Grant({
            startTime: currentTime() + _vestingCliffInDays * 1 days,
            amount: _amount,
            vestingDuration: _vestingDurationInDays,
            daysClaimed: 0,
            totalClaimed: 0,
            recipient: _recipient
        });
        tokenGrants[_recipient] = grant;
        emit GrantAdded(_recipient);
    }

    /// @notice Allows a grant recipient to claim their vested tokens. Errors if no tokens have vested
    function claimVestedTokens() external {
        uint16 daysVested;
        uint256 amountVested;
        (daysVested, amountVested) = calculateGrantClaim(msg.sender);
        require(amountVested > 0, "Vested is 0");

        Grant storage tokenGrant = tokenGrants[msg.sender];
        tokenGrant.daysClaimed = uint16(tokenGrant.daysClaimed + daysVested);
        tokenGrant.totalClaimed = uint256(tokenGrant.totalClaimed + amountVested);
        
        require(token.transfer(tokenGrant.recipient, amountVested), "no tokens");
        emit GrantTokensClaimed(tokenGrant.recipient, amountVested);
    }

    /// @notice Terminate token grant transferring all vested tokens to the `_recipient`
    /// and returning all non-vested tokens to the contract owner
    /// Secured to the contract owner only
    /// @param _recipient address of the token grant recipient
    function revokeTokenGrant(address _recipient) 
        external 
        onlyOwner
    {
        Grant storage tokenGrant = tokenGrants[_recipient];
        uint16 daysVested;
        uint256 amountVested;
        (daysVested, amountVested) = calculateGrantClaim(_recipient);

        uint256 amountNotVested = tokenGrant.amount - tokenGrant.totalClaimed - amountVested;

        require(token.transfer(owner(), amountNotVested));
        require(token.transfer(_recipient, amountVested));

        tokenGrant.startTime = 0;
        tokenGrant.amount = 0;
        tokenGrant.vestingDuration = 0;
        tokenGrant.daysClaimed = 0;
        tokenGrant.totalClaimed = 0;
        tokenGrant.recipient = address(0);

        emit GrantRevoked(_recipient, amountVested, amountNotVested);
    }

    function getGrantStartTime(address _recipient) external view returns(uint256) {
        Grant storage tokenGrant = tokenGrants[_recipient];
        return tokenGrant.startTime;
    }

    function getGrantAmount(address _recipient) external view returns(uint256) {
        Grant storage tokenGrant = tokenGrants[_recipient];
        return tokenGrant.amount;
    }

    /// @notice Calculate the vested and unclaimed months and tokens available for `_grantId` to claim
    /// Due to rounding errors once grant duration is reached, returns the entire left grant amount
    /// Returns (0, 0) if cliff has not been reached
    function calculateGrantClaim(address _recipient) private view returns (uint16, uint256) {
        Grant storage tokenGrant = tokenGrants[_recipient];

        require(tokenGrant.totalClaimed < tokenGrant.amount, "Grant fully claimed");

        // For grants created with a future start date, that hasn't been reached, return 0, 0
        if (currentTime() < tokenGrant.startTime) {
            return (0, 0);
        }

        // Check cliff was reached
        uint16 elapsedDays = uint16((currentTime() - (tokenGrant.startTime - 1 days)) / 1 days);

        // If over vesting duration, all tokens vested
        if (elapsedDays >= tokenGrant.vestingDuration) {
            uint256 remainingGrant = tokenGrant.amount - tokenGrant.totalClaimed;
            return (tokenGrant.vestingDuration, remainingGrant);
        } else {
            uint16 daysVested = elapsedDays - tokenGrant.daysClaimed;
            uint16 periodCount = tokenGrant.vestingDuration / vestingGranularityDays;
            uint16 periodsVested =  daysVested / vestingGranularityDays;
            uint256 amountVestedPerPeriod = uint256(tokenGrant.amount / periodCount);
            uint256 amountVested = uint256(periodsVested * amountVestedPerPeriod);
            return (daysVested, amountVested);
        }
    }

    function currentTime() private view returns(uint256) {
        return block.timestamp;
    }
}