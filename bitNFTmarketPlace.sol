// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

//Bit-NFT-Marketplace is a marketplace where you as a seller can list your erc721 tokens 
//for sale either on cash and carry basis or on installmental basis.
//It is a platform where buyers can buy NFT in dribs and drabs.
//sellers sends their nft to the contract using its address and the tokenId where it is secured.
//At the end of the duration of the sale which is 40 days,the seller gets his ether while the buyer gets his NFT
//if the buyer defaults,he/she forfeits 10% of total ether sent(5% for the marketplace and 5% compensation to the seller)
//And the seller gets back his NFT while the buyer gets back his ether minus 10% of total.
//If it is an instant sale,the marketplace receive 5% of the NFT price otherwise all funds go to seller..

contract BitNFTMarketPlace is Ownable{
     using Counters for Counters.Counter;
    //Deriving agreementId from Counters library
    Counters.Counter public agreementId;

    //All events to be emitted
    event NewNFTListed(address nftContractAddress,uint nftTokenId,address indexed seller,uint price);
    event NftBought(uint nftTokenId, address indexed seller,address indexed buyer, uint price);
    event LastBitPaid(uint nftTokenId,address indexed seller, address buyer, bool debtPaid);
    event BitBuy(address nftContractAddress,uint nftTokenId,address indexed seller, address buyer,uint price);
    event SellerClaim(uint nftTokenId,address indexed seller);
    event BuyerClaim(uint nftTokenId,address indexed buyer);
    event AgreementEnded(uint nftTokenId,address indexed sellerOrBuyer,bool saleEnded);
    event Received(address sender,uint amount, string message);
    


   
   //Modelling the agreement
    struct Agreements {
        address nftContractAddress;
        uint nftTokenId;
        address seller;
        uint agreementEndAt;
        bool saleEnded;
        uint price;
        bool onBit;
        //map amount paid in bit to each bit buyer
     mapping( address => uint) bit;
    }
    //mapping from agreementId => seller => totalPayForSeller
     mapping( uint => mapping(address => uint)) public totalPayForSeller;

    //Mapping each agreement to its agreementId
    mapping(uint => Agreements) public agreements;


    constructor () {        
    }

      modifier canListNFT(address _nftContractAddress, uint _nftTokenId){
        bool sellerOwnsNFT =  IERC721(_nftContractAddress).ownerOf( _nftTokenId) == msg.sender ? true
                                                            : false;
        require(sellerOwnsNFT, "You can only list only the NFT you own"); 
        _;       
    }
     modifier canBuyNow(uint _agreementId){ 
        Agreements storage agreement = agreements[_agreementId];       
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(msg.value >= agreement.price, "Value sent must be greater than or equal to NFT price");
        require(agreement.onBit == false,"A buyer has partly paid for this token");
        _;
    }
    modifier canBuyInBits(uint _agreementId){
        Agreements storage agreement = agreements[_agreementId];
         require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
         _;
    }
    modifier buyerCanClaimFund(uint _agreementId){
        Agreements storage agreement = agreements[_agreementId];
        require(agreement.bit[msg.sender] < agreement.price,"total payment made");
        require(agreement.saleEnded == false,"Agreement ended already");
       // require(bitLevel == LastBit,"All installments have not been paid");
        require(block.timestamp >= agreement.agreementEndAt,"The agreement has not ended yet");
        _;
    }
    modifier sellerCanClaimNFT(uint _agreementId){
          Agreements storage agreement = agreements[_agreementId];
        require(totalPayForSeller[_agreementId][msg.sender] < agreement.price,"Total payment made already");
        require(agreement.saleEnded == false,"Agreement ended already");
       // require(bitLevel != lastBits);
        require(block.timestamp < agreement.agreementEndAt,"The agreement has not ended yet");
        _;
    }
    modifier canPaylastBit(uint _agreementId){
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");   
        require(agreement.bit[msg.sender] == totalPayForSeller[_agreementId][agreement.seller],
        "Another address has partly paid for this token");
        require(agreement.bit[msg.sender] != agreement.price,"All instalments have been paid");
        require( block.timestamp < agreement.agreementEndAt,"agreement time has elapsed");
       // require(bitLevel != LastBits, "The last bit level has been hit");
        _;
    }
     modifier agreementEnded(uint _agreementId){ 
        Agreements storage agreement = agreements[_agreementId];       
        require(agreement.saleEnded == true && (block.timestamp >= agreement.agreementEndAt),"agreement duration has not ended");
        _;
    }

    //ListToken function help list NFT with its token contract address,tokenId and a price.
    //NFT can be bought between now and the next 40 days otherwise,it has to be re-listed 
    function listToken(address _nftContractAddress, uint _nftTokenId, uint _price) 
        public payable canListNFT(_nftContractAddress, _nftTokenId)returns (uint _Id) {
    //Approve before sending
        IERC721(_nftContractAddress).approve(address(this),_nftTokenId);
    //use openzepellin ERC721 safeTransferFrom function to transfer NFT token safely     
        IERC721(_nftContractAddress).safeTransferFrom(msg.sender, address(this), _nftTokenId);
    //update the agreementId of the NFT to be listed using Counters library
         uint currentId = agreementId.current();
        agreementId.increment();
        Agreements storage agreement = agreements[currentId];
    // update each property of the agreement struct
        agreement.nftContractAddress = _nftContractAddress;
        agreement.nftTokenId = _nftTokenId;
        agreement.seller = msg.sender;
        agreement.saleEnded = false;
        agreement.price = _price;
        agreement.onBit = false;
    //The real agreement time is for 40 days but for testing purpose,we use 4 hours
        agreement.agreementEndAt = block.timestamp + (4 hours); 
        emit NewNFTListed(_nftContractAddress,_nftTokenId,msg.sender, _price);  
    //check if the smart contract already got the NFT token
        bool contractGotToken =  IERC721(_nftContractAddress).ownerOf(_nftTokenId) == address(this) ? true : false;
        require(contractGotToken, "Untransfered token cannot be listed");   
        return currentId;             
    }

    //buyNow function is called when the buyer wishes to pay all the ether requested by the seller
    function buyNow(address _nftContractAddress,uint _agreementId,uint _nftTokenId,uint _price) public payable canBuyNow(_agreementId) returns(bool){
        Agreements storage agreement = agreements[ _agreementId];
    //calculate commission
        uint commisionedValue = (_price * 95) / 100;
        uint  contractValue = (_price * 5) / 100;
    //Prevent re-entrancy attack
        agreement.price = 0;
    //Buyer sends ether to the seller minus contract commission
        (bool done, ) = payable(agreement.seller).call{value: commisionedValue}("");
        require(done, "Cannot send ether to the seller");
    //Send contract commission in form of ether to the smart contract owner
        (bool etherSent, ) = payable(Ownable.owner()).call{value: contractValue}("");
        require(etherSent, "Cannot send ether to the contract owner");
   //Approve before sending
        IERC721(_nftContractAddress).approve(address(this),_nftTokenId);
    //Smart contract sends nft to the buyer
        IERC721(agreement.nftContractAddress).safeTransferFrom(address(this),msg.sender,_nftTokenId);
        agreement.onBit = false;
    //Emit the the info of the Nft bought to the frontend
        emit  NftBought(_nftTokenId,agreement.seller,msg.sender, _price);
        return agreement.saleEnded = true;
    }

    //BuyInBit function is called by buyers who intend to buy the NFT in installments.
    // Meanwhile a seller cannot buy his/her own token
    function buyInBit(address _nftContractAddress, uint _agreementId,uint _nftTokenId,uint _bit) public payable 
    canBuyInBits( _agreementId){
        Agreements storage agreement = agreements[_agreementId];
    //Bit buyer sends his bit or part payment to the smart contract
        (bool sent, ) = payable(address(this)).call{value: _bit}("");
        require(sent, "Cannot send ether to smart contract");
        agreement.onBit = true;
        agreement.bit[msg.sender] += _bit;
        totalPayForSeller[_agreementId][agreement.seller] += _bit;
        emit BitBuy(_nftContractAddress,_nftTokenId,agreement.seller,msg.sender,agreement.price);
    }

    //This function is called by the buyer who wants to pay his last bits and get his nft to end the agreement
    function payLastBit(address _nftContractAddress,uint _agreementId,uint _nftTokenId,uint _lastBit) public payable 
    canPaylastBit( _agreementId)
        returns (bool success){
        Agreements storage agreement = agreements[_agreementId];
      //The buyer sends the lastbit to the smart contract if these conditions are met.
      (bool sentEth, ) = payable(address(this)).call{value: _lastBit}("");
      require(sentEth, "ether could not be sent to the smart contract");
    //Get the balance the buyer has paid so far.    
        uint bal =  agreement.bit[msg.sender];
    //calculate commission
        uint commisionedValue = (bal * 95) / 100;
        uint  contractValue = (bal * 5) / 100;
    //Prevent re-entrancy attack
        agreement.bit[msg.sender] = 0;
    //Smart contract sends ether to the seller 
        (bool Sent, ) = payable(agreement.seller).call{value:  commisionedValue}("");
        require(Sent, "Cannot send ether to the seller");
    //Approve before sending
        IERC721(_nftContractAddress).approve(address(this),_nftTokenId);
    //Smart contract sends NFT to the buyer
        IERC721(agreement.nftContractAddress).safeTransferFrom(address(this),msg.sender,_nftTokenId);
    //Send contract commission in form of ether to the smart contract owner
        (bool etherSent, ) = payable(address(this)).call{value: contractValue}("");
        require(etherSent, "Cannot send ether to the contract owner");
        emit LastBitPaid(_nftTokenId,agreement.seller,msg.sender,success);
        emit AgreementEnded(_nftTokenId, agreement.seller, agreement.saleEnded);
        return (success);
    }

    //This function is used by the seller at the expiry of the installment agreement
    function sellerClaimNFT(address _nftContractAddress,uint _agreementId,uint _nftTokenId) external
     agreementEnded( _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
    //calculate seller's compensation   
        uint bal = agreement.bit[msg.sender];
        uint compensationValue = (bal * 10) / 100;
    //Approve before sending
        IERC721(_nftContractAddress).approve(address(this),_nftTokenId); 
    //Smart contract sends token to the seller
        IERC721(agreement.nftContractAddress).transferFrom(address(this),msg.sender,_nftTokenId);
    //Prevent re-entrancy attack
        totalPayForSeller[_agreementId][msg.sender] = 0;
        agreement.saleEnded == true;
    //Smart contract sends compensation ether to the seller
        (bool compensationSent, ) = payable(msg.sender).call{value:compensationValue}("");
        require(compensationSent, "Cannot send ether to the seller");
        emit SellerClaim( _nftTokenId, msg.sender);
        emit AgreementEnded(_nftTokenId, msg.sender,agreement.saleEnded);
    }

    //BuyerClaimFund function is used by the buyer to claim his nft when all installments are paid
    function buyerClaimFund(uint _agreementId,uint _nftTokenId) external 
    buyerCanClaimFund(_agreementId)  returns (bool success) {
        Agreements storage agreement = agreements[_agreementId];
    //calculate buyer's penalty   
        uint bal = agreement.bit[msg.sender];
        uint penaltyValue = (bal * 90) / 100;
    //Prevent re-entrancy attack    
        agreement.bit[msg.sender] = 0;
    //Smart contract sends ether to the buyer
        (bool penaltySent, ) = payable(msg.sender).call{value:penaltyValue}("");
        require( penaltySent, "Cannot send ether to the buyer"); 
        agreement.saleEnded == true;
        emit BuyerClaim(_nftTokenId,msg.sender); 
        emit AgreementEnded(_nftTokenId,msg.sender,agreement.saleEnded);
        return (success);
    }

    //A view function that returns  Bit-NFT-MarketPlace Commission
    function getBitMktCommision(uint _agreementId) internal view returns (uint) {
       Agreements storage  agreement = agreements[_agreementId];
        return (agreement.price * 5)/100;
    }
    //A view function that returns the fund receivable by an NFT seller
    function getSellersFundReceivable(uint _agreementId) internal view returns (uint) {
        Agreements storage agreement = agreements[_agreementId];
         return (agreement.price * 95)/100;
    }
     //fallback function helps the smart contract to receive ether
     fallback() external payable {
        emit Received(msg.sender, msg.value,"Fallback function was called");
    }
   //receive function helps the smart contract to receive ether
     receive() external payable {
        emit Received(msg.sender, msg.value,"Receive function was called");
    }
 //receive function helps the smart contract to receive NFT
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) public pure returns (bytes4) {
        return this.onERC721Received.selector ;
    }
    
}