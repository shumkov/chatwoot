/* global axios */
import ApiClient from '../ApiClient';

class UmiShopifyAPI extends ApiClient {
  constructor() {
    super('umi/shopify/conversations', { accountScoped: true });
  }

  commerce(conversationId, params = {}) {
    return axios.get(`${this.url}/${conversationId}`, { params });
  }

  customers(conversationId, query, after) {
    return axios.get(`${this.url}/${conversationId}/customers`, {
      params: { query, after },
    });
  }

  customer(conversationId, customerId) {
    return axios.put(`${this.url}/${conversationId}/customer`, {
      customer_id: customerId,
    });
  }

  preview(conversationId, reference) {
    return axios.post(`${this.url}/${conversationId}/preview`, { reference });
  }

  link(conversationId, preview) {
    return axios.post(`${this.url}/${conversationId}/links`, {
      reference: preview.admin_url,
      updated_at: preview.updated_at,
    });
  }

  unlink(conversationId, item) {
    return axios.delete(
      `${this.url}/${conversationId}/links/${item.kind}/${item.id}`
    );
  }

  refresh(conversationId) {
    return axios.post(`${this.url}/${conversationId}/refresh`);
  }
}

export default new UmiShopifyAPI();
