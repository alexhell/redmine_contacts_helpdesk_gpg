class GpgKeys

	def self.initGPG
		ENV.delete('GPG_AGENT_INFO') # this interfers otherwise with our tests
		ENV['GNUPGHOME'] = HelpDeskGPG.keyrings_dir
		GPGME::Engine.home_dir = HelpDeskGPG.keyrings_dir
		@@hkp = Hkp.new(HelpDeskGPG.keyserver)

		Rails.logger.info "Gpgkeys#initGPG using key rings in: #{HelpDeskGPG.keyrings_dir}"
		Rails.logger.info "Gpgkeys#initGPG using key server: #{HelpDeskGPG.keyserver}"
	end
	
	def self.visible(params)
		if params[:format].present? and params[:format] == 'filter'
			_keys = self.filter_keys(params)
		else 
			_keys = self.find_all_keys
		end
		return _keys
	end
	
	def self.sec_fingerprints
		return @@sec_fingerprints
	end
	
	def self.import_keys(params)
		_cnt_pub_old = GPGME::Key.find(:public).length
		_cnt_priv_old = GPGME::Key.find(:secret).length

		if params[:attachments]
			#Rails.logger.info "Gpgkeys#import has attachments"
			params[:attachments].each do |id, descr|
				_attached = Attachment.find_by_token(descr["token"]) 
				if (_attached)
					GPGME::Key.import(File.open(_attached.diskfile))
					_attached.delete_from_disk
				end
			end
		end
		
		_cnt_pub_new = GPGME::Key.find(:public).length - _cnt_pub_old
		_cnt_priv_new = GPGME::Key.find(:secret).length - _cnt_priv_old
		return [_cnt_pub_new, _cnt_priv_new]
	end
	
	def self.removeKey(fingerprint)
		_key = GPGME::Key.get(fingerprint)
		if _key 
			# Rails.logger.info "Gpgkeys#destroy found: #{_key.primary_uid.uid}"
			_key.delete!(true)
		end
	end

	# refresh all keys in keystore from public key server
	def self.refresh_keys
		_ctx = GPGME::Ctx.new()
		_keys = _ctx.keys(nil, false)
		for _key in _keys
			begin
				Rails.logger.info "Gpgkeys#refresh_key #{_key.fingerprint} <#{_key.email}>"
				@@hkp.fetch_and_import(_key.fingerprint)
			rescue #catch OpenURI::HTTPError 404 for keys not on key server
				Rails.logger.info "Gpgkeys#refresh_key caught error on #{_key.fingerprint}"
				next
			end
		end
		_ctx.release
	end # refresh_keys
	
	# remove expired keys from keystore
	def self.remove_expired_keys
		_cnt = 0
		_ctx = GPGME::Ctx.new()
		_keys = _ctx.keys(nil, false)
		for _key in _keys
			if self.keyExpiredOrRevoked(_key)
				_key.delete!(true)
				_cnt += 1
			end
		end
		Rails.logger.info "Gpgkeys#remove_expired_keys removed #{_cnt} keys"
		return _cnt
	end # remove_expired_keys

	## private 

	def self.find_all_keys
		_ctx = GPGME::Ctx.new()
		_keys = _ctx.keys(nil, false)
		@@sec_fingerprints = []
		_sec = _ctx.keys(nil, true)
		for key in _sec
			@@sec_fingerprints.push(key.subkeys[0].fingerprint)
		end
		_ctx.release
		return _keys
	end # find_all_keys
	
	def self.filter_keys(params)
		#Rails.logger.debug "Gpgkeys filter_keys (name='#{params[:name]}', secret='#{params[:secretonly]}', expired='#{params[:expiredonly]}')"
		_all_keys = find_all_keys
		_result = []
		if params[:name]
			for key in _all_keys
				_found = false
				for uid in key.instance_variable_get(:@uids)
					if uid.name.downcase.include? params[:name].downcase or uid.email.downcase.include? params[:name].downcase
						_result.push(key)
						_found = true
						break
					end
				end
				if _found and params[:secretonly]
					if not @@sec_fingerprints.include? key.subkeys[0].fingerprint
						_result.delete(key)
					end
				end
			end
		elsif params[:secretonly]
			for key in _all_keys
				if @@sec_fingerprints.include? key.subkeys[0].fingerprint
					_result.push(key)
				end
			end
		end
		
		if params[:expiredonly]
			_temp = _all_keys 
			if params[:name] or params[:secretonly]
				_temp = _result
			end
			_result = []
			for key in _temp
				if self.keyExpiredOrRevoked(key)
					_result.push(key)
				end
			end
		end
	
		return _result
	end # filter_keys

	def self.keyExpiredOrRevoked(_key)
		 _key.expired || _key.subkeys[0].trust == :revoked
	end # keyExpiredOrRevoked
end