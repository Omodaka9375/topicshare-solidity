pragma solidity 0.4.25;

import "installed_contracts/zeppelin/contracts/ownership/Ownable.sol";
import "installed_contracts/zeppelin/contracts/lifecycle/Pausable.sol";
import "installed_contracts/zeppelin/contracts/lifecycle/Destructible.sol";
import "installed_contracts/zeppelin/contracts/Strings.sol";
/// @title An interface for the Twitter Oracle contract
/// @notice The Twitter Oracle contract allows users to retrieve and store twitter post text onto the blockchain
interface TopicShareOracle {

    /// @notice Retrieve the tweet text for a given post stored in the contract
    /// @dev Returned string may come back in an array syntax and will need to be parsed by the front-end
    /// @param _postId The post id you want to retrieve text for. Expecting "<user>/status/<id>".
    /// @return string of the text for that post
    function getTweetText(string _postId) external view returns(string);

    /// @param _profileId The post id you want to retrieve text for. Expecting "<user>/status/<id>".
    /// @return string of the text for that post 
    function getFollowers(string _profileId) external view returns(string);

    /// @notice Oraclize tweet text for a given post and store it in the contract
    /// @dev Calling this function requires the Twitter Oracle contract has funds, thus this function is payable so the user can provide those funds
    /// @param _postId The post id you want to oraclize. Expecting "<user>/status/<id>".
    function oraclizeTweet(string _postId) external payable;

    /// @param _profileId The post id you want to oraclize. Expecting "<user>/status/<id>".
    function oraclizeFollowers(string _profileId) external payable;
}

/// @notice This contract follows many similar patterns to Bounties Network's StandardBounties.sol
contract TopicShareBounty is Ownable, Pausable, Destructible {
    using Strings for *;
    /* Storage */
    address public owner;
    Bounty[] public bounties;
    mapping(uint => Fulfillment[]) fulfillments;
    mapping(address => uint) public availableCalls;
    TopicShareOracle public oracleContract;
      
    uint public costPerCall = 1 ether;

    /* Structs */
    struct Bounty {
        address issuer;
        uint256 fulfillmentAmount;
        uint256 balance;
        string tweetText;
        string topic;
        string follows;
        bool bountyOpen;
        mapping (bytes32 => bool) tweetsUsed;
    }

    struct Fulfillment {
        uint256 fulfillmentAmount;
        address fulfiller;
        string tweetId;
    }

    /* Events */
    event BountyCreated(uint _bountyId);
    event BountyBought(uint _numOfCalls);
    event BountyFulfilled(uint _bountyId, address indexed _fulfiller, uint256 indexed _fulfillmentId);
    event ContributionAdded(uint _bountyId, address indexed _contributor, uint256 _value);
    event BountyClosed(uint _bountyId, address indexed _issuer);
    event PayoutChanged(uint _bountyId, uint _newFulfillmentAmount);

    /* Modifiers */
    /// @notice Checks that the amount is not equal to zero
    /// @dev To be used in situations like funding a bounty and setting the bounty fulfillment reward
    /// @param _amount The amount to be checked
    modifier amountIsNotZero(uint256 _amount) {
        require (
            _amount != 0,
            "The amount cannot be zero."
            );
        _;
    }

    /// @notice Checks that the bounty array won't overflow
    /// @dev To be used before a new bounty is created
    modifier validateNotTooManyBounties() {
        require(
            (bounties.length + 1) > bounties.length,
            "There are too many bounties registered, causing an overflow."
            );
        _;
    }

    /// @dev Cheap way to convert string to int  
    function parseInt(string _a, uint _b) internal pure returns (uint) {
        bytes memory bresult = bytes(_a);
        uint mint = 0;
        bool decimals = false;
        for (uint i = 0; i < bresult.length; i++) {
            if ((bresult[i] >= 48) && (bresult[i] <= 57)) {
            if (decimals) {
                if (_b == 0) break;
                else _b--;
            }
            mint *= 10;
            mint += uint(bresult[i]) - 48;
            } else if (bresult[i] == 46) decimals = true;
        }
        return mint;
    }

    /// @notice Checks that the number of fulfillments won't overflow for a specific bounty
    /// @dev To be used before a new fulfillment is created for a bounty
    /// @param _bountyId The bounty to check fulfillments for
    modifier validateNotTooManyFulfillments(uint _bountyId) {
        require(
            (fulfillments[_bountyId].length + 1) > fulfillments[_bountyId].length,
            "There are too many fulfillments for this bounty, causing an overflow."
            );
        _;
    }

    /// @notice Checks that a specific Bounty ID is within the range of registered bounties
    /// @dev To be used in any situation where we are accessing an existing bounty
    /// @param _bountyId The Bounty ID to validate
    modifier validateBountyArrayIndex(uint _bountyId){
        require(
            _bountyId < bounties.length,
            "Invalid Bounty ID."
            );
        _;
    }

    /// @notice Checks that a specific profile has enough followers
    /// @param _bountyId The Bounty ID to validate
    /// @param _postId The  post ID to extract profile from
    modifier validateFollowersCount(uint _bountyId, string _postId){
        require(
             parseInt(bounties[_bountyId].follows,0) <= parseInt(getFollowers(_postId.toSlice().split("/".toSlice()).toString()),0),
            "There are not enough followers to claim the reward."
            );
        _;
    }

    /// @notice Checks that a specific Bounty ID is open
    /// @dev To be used in any situation where a bounty is being modified or fulfilled
    /// @param _bountyId The Bounty ID to check if open
    modifier isOpen(uint _bountyId) {
        require(
            bounties[_bountyId].bountyOpen == true,
            "Bounty is not open."
            );
        _;
    }

    /// @notice Checks that the the function is being called by the owner of the bounty
    /// @dev To be used in any situation where the function performs a privledged action to the bounty
    /// @param _bountyId The Bounty ID to check the owner of
    modifier onlyIssuer(uint _bountyId) {
        require(
            bounties[_bountyId].issuer == msg.sender || msg.sender == owner,
            "Only the issuer of this bounty can call this function."
            );
        _;
    }

    /// @notice Checks that the the function is being called by the owner of the bounty
    /// @dev To be used in any situation where the function performs a privledged action to the bounty
    /// @param _bountyId The Bounty ID to check the owner of
    modifier onlyIssuerOrOwner(uint _bountyId) {
        require(
            bounties[_bountyId].issuer == msg.sender || msg.sender == owner,
            "Only the issuer of this bounty or owner can call this function."
            );
        _;
    }

    /// @notice Checking that they are eligible for the call
    modifier onlyIfEnoughCalls() {
        require(
            availableCalls[msg.sender] > 0,
            "Can't create campaign without initializing it first."
            );
        _;
    }
    
    /// @notice Checks that the bounty has enough of a balance to pay a fulfillment
    /// @dev To be used before a fulfillment is completed
    /// @param _bountyId The Bounty ID to check the balance of
    modifier enoughFundsToPay(uint _bountyId) {
        require(
            bounties[_bountyId].balance >= bounties[_bountyId].fulfillmentAmount,
            "The fulfillment amount is more than the balance available for this bounty."
            );
        _;
    }

    /// @notice Checks that a specific Fulfillment ID is within the range of fullfillments for a bounty
    /// @dev To be used in any situation where we are accessing a fulfillment
    /// @param _bountyId The Bounty ID which has the fulfillment to be checked
    /// @param _index The index of the fulfillment to be checked
    modifier validateFulfillmentArrayIndex(uint _bountyId, uint _index) {
        require(
            _index < fulfillments[_bountyId].length,
            "Invalid Fulfillment ID."
            );
        _;
    }

    /// @notice Check that the text for a tweet is not empty
    /// @dev An empty tweet text implies that the tweet was not oraclized, or failed to oraclize
    /// @param _postId The tweet id to check. Expecting "<user>/status/<id>"
    modifier tweetTextNotEmpty(string _postId) {
        require(
            keccak256(abi.encodePacked(getTweetText(_postId))) != keccak256(""),
            "The tweet text is empty. This tweet may have never been oraclized, or may have run into an issue when oraclizing."
            );
        _;
    }

    /* Functions */
    /// @notice Constructor function which establishes the contract owner and initializes the Twitter Oracle address
    /// @dev Ownership can be managed through Open-Zeppelin's Ownable.sol which this contract uses. Oracle address can be updated using SetOracle
    /// @param _addr The address of the Twitter Oracle contract
    constructor(address _addr)
    public
    {
        owner = msg.sender;
        setOracle(_addr);
    }

    /// @notice The fallback function for the contract
    /// @dev Will simply revert any unexpected calls
    function()
    public
    {
        revert("Fallback function. Reverting...");
    }

    /// @notice Allows the contract to update the Twitter Oracle it uses for creating bounties
    /// @dev Only the owner of this contract can call this function
    /// @param _addr The address of the Twitter Oracle contract
    function setOracle(address _addr)
    public
    onlyOwner
    {
        oracleContract = TopicShareOracle(_addr);
    }

    function getFee()
    public
    view
    returns
    (uint)
    {
        return costPerCall;
    }

    /// @dev Only the owner of this contract can call this function
    /// @param _cost the cost of creating a campaign
    function setCallCost(uint _cost)
    public
    onlyOwner
    {
        costPerCall = _cost;
    }

    /// @notice This function allows anyone to add additional funds to an open bounty
    /// @dev Note that these funds are under full control of the bounty creator, and the bounty can be closed and drained at any time
    /// @param _bountyId The bounty that the user wants to contribute to
    function contribute(uint _bountyId)
    public
    payable
    whenNotPaused
    validateBountyArrayIndex(_bountyId)
    isOpen(_bountyId)
    {
        bounties[_bountyId].balance += msg.value;
        emit ContributionAdded(_bountyId, msg.sender, msg.value);
    }

    /// @notice Allows anyone to buy calls for creating campaigns
    function buyCalls() 
    public 
    payable
    {
        require(msg.value > 0, "You need to send some ether with the transaction!");
        owner.transfer(msg.value);
        uint callsPurchased = msg.value / costPerCall;
        availableCalls[msg.sender] += callsPurchased;
        emit BountyBought(callsPurchased);
    }

    /// @notice This function will create a new open bounty using a stored tweet text
    /// @dev This function only works if the contract is not paused, if the fulfillment is greater than zero, there are room to make more bounties, and the tweet text has content.
    /// @param _fulfillmentAmount The amount a user will be paid when they fulfill a bounty
    /// @param _postId The post that will be used to establish the text requirements for this bounty
    /// @param _topic The amount a user will be paid when they fulfill a bounty
    /// @param _follows The post that will be used to establish the text requirements for this bounty
    /// @return The bountyId that was created as a result of this function call
    function createBounty (
        uint256 _fulfillmentAmount,
        string _postId,
        string _topic,
        string _follows
    )
    public
    payable
    whenNotPaused
    onlyIfEnoughCalls
    amountIsNotZero(_fulfillmentAmount)
    validateNotTooManyBounties
    tweetTextNotEmpty(_postId)
    returns (uint)
    {
        bounties.push(Bounty(msg.sender, _fulfillmentAmount, msg.value, getTweetText(_postId), _topic, _follows, true));
        bounties[bounties.length - 1].tweetsUsed[keccak256(abi.encodePacked(_postId))] = true;
        availableCalls[msg.sender]--;
        emit BountyCreated(bounties.length - 1);
        return (bounties.length - 1);
    }
    /// @notice This function allows any user to fulfill an open bounty using a post saved to the Twitter Oracle contract, and will automatically pay out
    /// @dev This function only works if there are enough funds to pay someone and if the bounty is open.
    /// @param _bountyId The bounty that the user is trying to fulfill
    /// @param _postId The Twitter post that will be used to try and fulfill the bounty
    /// @return Returns true if fulfillment completes. Can be used to check the function before it is actually run using .call()
    function fulfillBounty(uint _bountyId, string _postId)
    public
    whenNotPaused
    validateBountyArrayIndex(_bountyId)
    validateNotTooManyFulfillments(_bountyId)
    isOpen(_bountyId)
    enoughFundsToPay(_bountyId)
    validateFollowersCount(_bountyId, _postId)
    returns (bool)
    {
        require(
            bounties[_bountyId].tweetsUsed[keccak256(abi.encodePacked(_postId))] != true,
            "The tweet you are trying to use has already been used for this bounty."
            );
        require(
            keccak256(abi.encodePacked(bounties[_bountyId].tweetText)) == keccak256(abi.encodePacked(getTweetText(_postId))),
            "The tweet you are trying to use does not match the bounty text."
            );

        bounties[_bountyId].tweetsUsed[keccak256(abi.encodePacked(_postId))] = true;
        fulfillments[_bountyId].push(Fulfillment(bounties[_bountyId].fulfillmentAmount, msg.sender, _postId));
        bounties[_bountyId].balance -= bounties[_bountyId].fulfillmentAmount;
        msg.sender.transfer(bounties[_bountyId].fulfillmentAmount);
        emit BountyFulfilled(_bountyId, msg.sender, (fulfillments[_bountyId].length - 1));
        return true;
    }

    /// @notice This function allows the owner of a bounty to change the fulfillment amount for that bounty
    /// @dev This function requires that the new fulfillment amount is less than available balance for the bounty, which is why this function is also payable
    /// @param _bountyId The bounty the owner is trying to changet the fulfillment amount for
    /// @param _newFulfillmentAmount The new amount that users who fulfill the bounty will be paid 
    function changePayout(uint _bountyId, uint _newFulfillmentAmount)
    public
    payable
    whenNotPaused
    validateBountyArrayIndex(_bountyId)
    onlyIssuer(_bountyId)
    isOpen(_bountyId)
    {
        bounties[_bountyId].balance += msg.value;
        require(
            bounties[_bountyId].balance >= _newFulfillmentAmount,
            "Make sure the fulfillment amount is not more than the current bounty balance."
            );
        bounties[_bountyId].fulfillmentAmount = _newFulfillmentAmount;
        emit PayoutChanged(_bountyId, _newFulfillmentAmount);
    }

    /// @notice This function allows the owner of a bounty to close that bounty, and drain all funds from the bounty
    /// @dev Only the bounty creator can call this function
    /// @param _bountyId The bounty the owner wants to close
    function closeBounty(uint _bountyId)
    public
    whenNotPaused
    validateBountyArrayIndex(_bountyId)
    onlyIssuerOrOwner(_bountyId)
    {
        bounties[_bountyId].bountyOpen = false;
        uint tempBalance = bounties[_bountyId].balance;
        bounties[_bountyId].balance = 0;
        if (tempBalance > 0) {
            bounties[_bountyId].issuer.transfer(tempBalance);
        }
        emit BountyClosed(_bountyId, msg.sender);
    }

    /// @notice Returns the details of a bounty
    /// @dev It does not include the mapping of tweets used to fulfill the bounty
    /// @param _bountyId The bounty that should be retrieved
    /// @return A tuple of the bounty details
    function getBounty(uint _bountyId)
    public
    view
    validateBountyArrayIndex(_bountyId)
    returns (address, string, string, string, uint, uint, bool)
    {
        return (
            bounties[_bountyId].issuer,
            bounties[_bountyId].tweetText,
            bounties[_bountyId].topic,
            bounties[_bountyId].follows,
            bounties[_bountyId].fulfillmentAmount,
            bounties[_bountyId].balance,
            bounties[_bountyId].bountyOpen
        );
    }

    /// @notice Checks if a specific Tweet has already been used for a bounty
    /// @dev Can be used to proactively check for problems before the user submits a transaction
    /// @param _bountyId The bounty to check for tweets used
    /// @param _postId The twitter post to check if it was already used
    /// @return Returns true if the post has been used, otherwise it returns false
    function checkBountyTweetsUsed(uint _bountyId, string _postId)
    public
    view
    validateBountyArrayIndex(_bountyId)
    returns (bool)
    {
        return (bounties[_bountyId].tweetsUsed[keccak256(abi.encodePacked(_postId))]);
    }

    /// @return Returns true if the post has been used, otherwise it returns false
    function checkCalls()
    public
    view
    returns (bool)
    {
        return availableCalls[msg.sender] > 0;
    }

    /// @notice Returns the number of bounties registered in the contract
    /// @dev Can be used to iterate over all the bounties in the contract
    /// @return Returns the number of bounties
    function getNumBounties()
    public
    view
    returns (uint)
    {
        return bounties.length;
    }

    /// @notice Returns the number of fulfillments completed for a bounty
    /// @dev Can be used to iterate over all the fulfillments for a bounty
    /// @param _bountyId The bounty to get the number of fulfillments for
    /// @return Returns the number of fulfillments for a bounty
    function getNumFulfillments(uint _bountyId)
    public
    view
    returns (uint)
    {
        return fulfillments[_bountyId].length;
    }

    /// @notice Gets the fulfillment details for a specific bounty and fulfillment
    /// @param _bountyId The bounty which has the fulfillment to be returned
    /// @param _fulfillmentId The fulfillment to be returned
    /// @return Returns a tuple of details for the fulfillment
    function getFulfillment(uint _bountyId, uint _fulfillmentId)
    public
    view
    validateBountyArrayIndex(_bountyId)
    validateFulfillmentArrayIndex(_bountyId, _fulfillmentId)
    returns (uint256, address, string)
    {
        return (
            fulfillments[_bountyId][_fulfillmentId].fulfillmentAmount,
            fulfillments[_bountyId][_fulfillmentId].fulfiller,
            fulfillments[_bountyId][_fulfillmentId].tweetId
        );
    }

    /* Twitter Oracle Functions */
    /// @notice Gets the tweet text for a twitter post from the Twitter Oracle
    /// @dev Simply a passthrough function for the Twitter Oracle contract
    /// @param _postId The twitter post to get the text for
    /// @return Returns text for the twitter post, or in the case where the post hasn't been stored yet, it will return an empty string
    function getTweetText(string _postId)
    public
    view
    returns(string)
    {
        return oracleContract.getTweetText(_postId);
    }
    /// @param _profileId The twitter post to get the text for
    /// @return Returns text for the twitter post, or in the case where the post hasn't been stored yet, it will return an empty string
    function getFollowers(string _profileId)
    public
    view
    returns(string)
    {
        return oracleContract.getFollowers(_profileId);
    }

    /// @notice Requests the Twitter Oracle contract to retrieve and store the tweet text for a Twitter post
    /// @dev The Twitter Oracle contract requires funds to support storing the Oraclize callback, which is why this function is Payable, and will forward funds to the Twitter Oracle
    /// @param _postId The twitter post to retrieve and store in the Twitter Oracle contract
    function oraclizeTweet(string _postId)
    public
    payable
    whenNotPaused
    {
        oracleContract.oraclizeTweet.value(msg.value)(_postId);
    }
    
    /// @param _profileId The twitter post to retrieve and store in the Twitter Oracle contract
    function oraclizeFollowers(string _profileId)
    public
    payable
    whenNotPaused
    {
        oracleContract.oraclizeFollowers.value(msg.value)(_profileId);
    } 
}