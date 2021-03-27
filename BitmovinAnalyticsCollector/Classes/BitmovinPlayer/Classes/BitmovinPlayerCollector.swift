import Foundation
import BitmovinPlayer

public class BitmovinPlayerCollector : BitmovinAnalyticsInternal {
    
    @objc public override init(config: BitmovinAnalyticsConfig) {
        super.init(config: config);
    }
    /**
     * Attach a player instance to this analytics plugin. After this is completed, BitmovinAnalytics
     * will start monitoring and sending analytics data based on the attached player instance.
     */
    @objc public func attachPlayer(player: Player) {
        print("BitmovinPlayerCollector::attachPlayer() %@", type(of: player))
        let autoplay = player.config.playbackConfiguration.isAutoplayEnabled && player.config.sourceItem != nil
        attach(adapter: BitmovinPlayerAdapter(player: player, config: config, stateMachine: stateMachine), autoplay: autoplay)
        if (self.adAnalytics != nil) {
            attachAd(adAdapter: BitmovinAdAdapter(bitmovinPlayer: player, adAnalytics: self.adAnalytics!))
        }
    }

}
